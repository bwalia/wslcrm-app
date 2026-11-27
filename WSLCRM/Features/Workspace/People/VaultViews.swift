import SwiftUI

// MARK: - Rules and words

/// The vault's fixed vocabulary and rules (`lapis/queries/SecretVaultQueries.lua`, `migrations/secret-vault.lua`).
enum VaultRules {
    static let keyLength = 16

    /// nil when the key is acceptable, else what to say. The server's rule: exactly 16 characters with
    /// at least one letter and one number.
    static func keyProblem(_ key: String) -> String? {
        if key.count != keyLength { return "The vault key must be exactly \(keyLength) characters (it has \(key.count))." }
        if key.rangeOfCharacter(from: .letters) == nil || key.rangeOfCharacter(from: .decimalDigits) == nil {
            return "The vault key needs at least one letter and one number."
        }
        return nil
    }

    /// Only the types the database accepts (the web also offers "credential" and "other", which it rejects).
    static let types: [Choice] = [
        Choice("generic", "Generic"), Choice("password", "Password"), Choice("api_key", "API key"),
        Choice("ssh_key", "SSH key"), Choice("certificate", "Certificate"), Choice("database", "Database"),
        Choice("oauth_token", "OAuth token"), Choice("credit_card", "Credit card"), Choice("note", "Note"),
        Choice("env_variable", "Environment variable"), Choice("license_key", "Licence key"),
        Choice("webhook_secret", "Webhook secret"), Choice("encryption_key", "Encryption key"),
    ]

    static func typeLabel(_ value: String?) -> String {
        guard let value else { return "Generic" }
        return types.first { $0.value == value }?.label ?? Formatters.humanize(value)
    }

    static func typeSymbol(_ value: String?) -> String {
        switch value {
        case "password": "key.horizontal"
        case "api_key", "oauth_token", "webhook_secret": "key"
        case "ssh_key", "encryption_key": "lock.rectangle"
        case "certificate": "checkmark.seal"
        case "database": "cylinder"
        case "credit_card": "creditcard"
        case "note": "note.text"
        case "env_variable": "terminal"
        case "license_key": "ticket"
        default: "lock.doc"
        }
    }

    static let logActions: [Choice] = [
        Choice("vault_create", "Vault created"), Choice("vault_unlock", "Vault unlocked"),
        Choice("vault_lock", "Vault locked"), Choice("vault_key_change", "Vault key changed"),
        Choice("vault_delete", "Vault deleted"), Choice("failed_unlock", "Wrong vault key"),
        Choice("secret_create", "Secret added"), Choice("secret_read", "Secret shown or copied"),
        Choice("secret_update", "Secret changed"), Choice("secret_delete", "Secret deleted"),
        Choice("secret_rotate", "Secret value replaced"), Choice("secret_share", "Secret shared"),
        Choice("share_accept", "Share accepted"), Choice("share_revoke", "Share stopped"),
        Choice("folder_create", "Folder added"), Choice("folder_update", "Folder changed"),
        Choice("folder_delete", "Folder deleted"), Choice("bulk_import", "Secrets imported"),
        Choice("bulk_export", "Secrets exported"),
    ]

    static func logLabel(_ value: String?) -> String {
        guard let value else { return "Activity" }
        return logActions.first { $0.value == value }?.label ?? Formatters.humanize(value)
    }

    static let folderColours: [Choice] = [
        Choice("blue", "Blue"), Choice("green", "Green"), Choice("purple", "Purple"), Choice("orange", "Orange"),
        Choice("red", "Red"), Choice("gray", "Grey"),
    ]

    /// What a person types for a secret, before it is sent.
    struct Draft: Equatable {
        var name = ""
        var value = ""
        var type = "password"
        var description = ""
        var tags = ""
        var username = ""
        var url = ""
        var expiresAt: Date?
        var rotationAt: Date?

        init() {}

        /// From a secret read in full (`GET /secrets/:id`: value and metadata included).
        init(_ secret: Record) {
            name = secret.string("name") ?? ""
            type = secret.string("secret_type") ?? "generic"
            description = secret.string("description") ?? ""
            tags = VaultRules.tags(secret).joined(separator: ", ")
            username = secret.string("metadata.username") ?? ""
            url = secret.string("metadata.url") ?? ""
            expiresAt = secret.date("expires_at")
            rotationAt = secret.date("rotation_reminder_at")
        }

        var tagList: [String] {
            tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        /// The metadata the web keeps with a secret (`{"url", "username"}`), as the JSON text the server stores.
        var metadataText: String {
            var fields: [String: JSONValue] = [:]
            if let username = username.trimmedOrNil { fields["username"] = .string(username) }
            if let url = url.trimmedOrNil { fields["url"] = .string(url) }
            guard !fields.isEmpty, let data = try? JSONEncoder.sorted.encode(JSONValue.object(fields)) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }

        var tagsText: String {
            let data = (try? JSONEncoder.sorted.encode(JSONValue.array(tagList.map(JSONValue.string)))) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        /// The form fields for `POST /secrets` (new) or `PUT /secrets/:id`. Tags aren't sent with a new
        /// secret: the server would store them encoded twice, so they follow in a save of their own.
        func fields(isNew: Bool) -> [(String, String)] {
            var fields: [(String, String)] = [("name", name.trimmingCharacters(in: .whitespacesAndNewlines)),
                                              ("secret_type", type)]
            if isNew || !value.isEmpty { fields.append(("value", value)) }
            if isNew {
                if let description = description.trimmedOrNil { fields.append(("description", description)) }
                if !metadataText.isEmpty { fields.append(("metadata", metadataText)) }
            } else {
                fields.append(("description", description.trimmingCharacters(in: .whitespacesAndNewlines)))
                fields.append(("metadata", metadataText))  // "" clears it
                fields.append(("tags", tagsText))
            }
            if let expiresAt { fields.append(("expires_at", APIDate.string(from: expiresAt))) }
            if let rotationAt { fields.append(("rotation_reminder_at", APIDate.string(from: rotationAt))) }
            return fields
        }
    }

    /// A secret's tags: an array, JSON text, or (after a web create) JSON text inside JSON text.
    static func tags(_ secret: Record) -> [String] {
        let direct = secret.array("tags").compactMap(\.stringValue)
        if !direct.isEmpty { return direct }
        if let text = secret.string("tags"), let data = text.data(using: .utf8),
           let inner = try? JSONDecoder().decode(String.self, from: data),
           let decoded = try? JSONDecoder().decode([String].self, from: Data(inner.utf8)) {
            return decoded
        }
        return []
    }
}

// MARK: - The vault while the screen is open

/// One person's vault in this workspace. The vault key lives only here, in memory, while the screen
/// is open: it is never saved, and "Lock" forgets it.
@MainActor
@Observable
final class VaultStore {
    enum Phase {
        case loading
        case failed(APIError)
        case none
        case locked
        case unlocked
    }

    private(set) var phase: Phase = .loading
    private(set) var vault: Record?
    private(set) var stats: Record?
    private(set) var folders: [Record] = []
    private(set) var secrets: [Record] = []
    private(set) var shared: [Record] = []
    private(set) var listError: APIError?
    var search = ""
    var typeFilter = ""
    @ObservationIgnored private var key: String?
    @ObservationIgnored let api: WorkspaceAPI

    init(api: WorkspaceAPI) {
        self.api = api
    }

    // MARK: Opening

    func start() async {
        do {
            let json = try await api.get("/api/v2/vault")
            vault = WorkspaceAPI.record(json)
            phase = key == nil ? .locked : .unlocked
            if key != nil { await refresh() }
        } catch {
            let apiError = error.asAPIError
            if case .notFound = apiError { phase = .none; return }
            if case .cancelled = apiError { return }
            phase = .failed(apiError)
        }
    }

    func create(key newKey: String, name: String) async throws {
        var fields = [("vault_key", newKey)]
        if let name = name.trimmedOrNil { fields.append(("name", name)) }
        let json = try await api.sendForm(.post, "/api/v2/vault", fields: fields)
        vault = WorkspaceAPI.record(json)
        key = newKey
        phase = .unlocked
        await refresh()
    }

    func unlock(_ candidate: String) async throws {
        _ = try await keyed(.post, "/api/v2/vault/unlock", key: candidate)
        key = candidate
        phase = .unlocked
        await refresh()
    }

    /// Forgets the key: everything secret needs it typed again.
    func lock() {
        key = nil
        folders = []
        secrets = []
        shared = []
        phase = .locked
    }

    func changeKey(from old: String, to new: String) async throws {
        _ = try await keyed(.put, "/api/v2/vault/key", key: old,
                            fields: [("old_vault_key", old), ("new_vault_key", new)])
        key = new
    }

    // MARK: Lists

    func refresh() async {
        let api = self.api
        async let statsCall = try? api.get("/api/v2/vault/stats")
        async let sharedCall = try? api.get("/api/v2/vault/shared")
        await loadFolders()
        await loadSecrets()
        if let json = await statsCall { stats = WorkspaceAPI.record(json) }
        if let json = await sharedCall { shared = WorkspaceAPI.records(json) }
        if let json = try? await api.get("/api/v2/vault") { vault = WorkspaceAPI.record(json) ?? vault }
    }

    func loadFolders() async {
        do {
            folders = WorkspaceAPI.records(try await keyed(.get, "/api/v2/vault/folders"))
        } catch {
            listError = error.asAPIError
        }
    }

    func loadSecrets() async {
        do {
            let json = try await keyed(.get, "/api/v2/vault/secrets",
                                       query: ["search": search, "secret_type": typeFilter, "per_page": "500"])
            secrets = WorkspaceAPI.records(json)
            listError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            listError = apiError
        }
    }

    // MARK: Secrets

    /// The whole secret, value included. The server records this as a read in the access log.
    func secret(_ id: String) async throws -> Record {
        let json = try await keyed(.get, "/api/v2/vault/secrets/\(Self.path(id))")
        guard let record = WorkspaceAPI.record(json) else { throw ResourceService.problem(404, "This secret wasn’t found.") }
        return record
    }

    func save(_ draft: VaultRules.Draft, existing: Record?) async throws {
        if let existing {
            _ = try await keyed(.put, "/api/v2/vault/secrets/\(Self.path(existing.id))", fields: draft.fields(isNew: false))
        } else {
            let json = try await keyed(.post, "/api/v2/vault/secrets", fields: draft.fields(isNew: true))
            if !draft.tagList.isEmpty, let created = WorkspaceAPI.record(json) {
                _ = try await keyed(.put, "/api/v2/vault/secrets/\(Self.path(created.id))",
                                    fields: [("tags", draft.tagsText)])
            }
        }
        await refresh()
    }

    func deleteSecret(_ id: String) async throws {
        _ = try await keyed(.delete, "/api/v2/vault/secrets/\(Self.path(id))")
        await refresh()
    }

    // MARK: Folders

    func saveFolder(existing: Record?, name: String, description: String, colour: String) async throws {
        var fields = [("name", name.trimmingCharacters(in: .whitespacesAndNewlines)),
                      ("description", description.trimmingCharacters(in: .whitespacesAndNewlines))]
        if !colour.isEmpty { fields.append(("color", colour)) }
        if let existing {
            _ = try await keyed(.put, "/api/v2/vault/folders/\(Self.path(existing.id))", fields: fields)
        } else {
            _ = try await keyed(.post, "/api/v2/vault/folders", fields: fields)
        }
        await refresh()
    }

    func deleteFolder(_ id: String) async throws {
        _ = try await keyed(.delete, "/api/v2/vault/folders/\(Self.path(id))")
        await refresh()
    }

    // MARK: Sharing

    func shares(of secretID: String) async throws -> [Record] {
        WorkspaceAPI.records(try await api.get("/api/v2/vault/secrets/\(Self.path(secretID))/shares"))
    }

    func share(_ secretID: String, with userID: String, theirKey: String, permission: String, canReshare: Bool,
               expiresAt: Date?, message: String) async throws {
        var fields = [("target_user_id", userID), ("target_vault_key", theirKey), ("permission", permission),
                      ("can_reshare", canReshare ? "true" : "false")]
        if let expiresAt { fields.append(("expires_at", APIDate.string(from: expiresAt))) }
        if let message = message.trimmedOrNil { fields.append(("message", message)) }
        _ = try await keyed(.post, "/api/v2/vault/secrets/\(Self.path(secretID))/share", fields: fields)
        await refresh()
    }

    func revokeShare(_ shareID: String) async throws {
        try await api.send(.delete, "/api/v2/vault/shares/\(Self.path(shareID))")
        await refresh()
    }

    /// Workspace members to share with (`{id, uuid, email, first_name, last_name, username, has_vault}`).
    func people(matching query: String) async throws -> [Record] {
        WorkspaceAPI.records(try await api.get("/api/v2/vault/users/search", query: ["q": query, "limit": "20"]))
    }

    // MARK: Access log

    func logs(page: Int, action: String, from: Date?, to: Date?) async throws -> Page<Record> {
        let json = try await api.get("/api/v2/vault/logs", query: [
            "page": String(page), "per_page": "30", "action": action,
            "start_date": from.map(AuditLogVocabulary.dayStart), "end_date": to.map(AuditLogVocabulary.dayEnd),
        ])
        return WorkspaceAPI.page(json, page: page, perPage: 30)
    }

    // MARK: Sending the key

    /// A call that carries the vault key (`X-Vault-Key`, form-encoded body).
    ///
    /// OpsAPI answers a wrong vault key with 401. These calls tell the client that a 401 here is about
    /// the vault key, not the sign-in (`unauthorizedEndsSession = false`), so a wrong key never signs
    /// the person out. The client still renews a sign-in that's about to expire before sending.
    private func keyed(_ method: HTTPMethod, _ path: String, key override: String? = nil,
                       fields: [(String, String)] = [], query: [String: String?] = [:]) async throws -> JSONValue {
        guard let vaultKey = override ?? key else {
            throw ResourceService.problem(400, "Unlock the vault first.")
        }
        var items = QueryBuilder()
        for (name, value) in query.sorted(by: { $0.key < $1.key }) { items.add(name, value) }
        var endpoint = Endpoint(method, path, query: items.items, requiresAuth: true, requiresNamespace: true)
        endpoint.unauthorizedEndsSession = false
        if let target = api.target { endpoint.namespaceOverride = target.uuid }
        if !fields.isEmpty || method == .post || method == .put { endpoint = endpoint.withForm(fields) }
        endpoint.headers["X-Vault-Key"] = vaultKey
        do {
            let (data, _) = try await api.client.sendRaw(endpoint)
            return data.isEmpty ? .null : ((try? ResourceService.decode(data)) ?? .null)
        } catch let error as APIError {
            throw Self.explain(error)
        }
    }

    /// The vault's own errors in plain words.
    nonisolated static func explain(_ error: APIError) -> APIError {
        guard let server = error.serverError else { return error }
        let message = server.message.lowercased()
        if message.contains("invalid vault key") || (server.status == 401 && message.contains("vault")) {
            return ResourceService.problem(422, "That vault key isn’t right. Check it and try again. "
                                           + "After 5 wrong tries the vault locks for 30 minutes.")
        }
        if server.status == 423 || message.contains("locked") {
            return ResourceService.problem(422, "The vault is locked after too many wrong keys. Try again in 30 minutes.")
        }
        return error
    }

    nonisolated private static func path(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    }
}

// MARK: - Screens

/// The secret vault: a private, encrypted store of passwords and keys for each person in the workspace.
struct VaultScreen: View {
    @Environment(\.services) private var services

    var body: some View {
        ModelHost(make: { VaultStore(api: services.workspace()) }) { store in
            VaultRoot(store: store)
        }
        .navigationTitle("Secret vault")
    }
}

private struct VaultRoot: View {
    @Bindable var store: VaultStore

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                SkeletonList()
            case .failed(let error):
                ErrorStateView(error: error) { Task { await store.start() } }
            case .none:
                VaultSetupForm(store: store)
            case .locked:
                VaultUnlockForm(store: store)
            case .unlocked:
                VaultHome(store: store)
            }
        }
        .task { await store.start() }
    }
}

private struct VaultSetupForm: View {
    let store: VaultStore
    @State private var key = ""
    @State private var confirm = ""
    @State private var name = "My Vault"
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var working = false

    var body: some View {
        Form {
            Section {
                Label("Keep passwords, API keys and other secrets here, encrypted with a key only you know.",
                      systemImage: "lock.shield")
            }
            Section {
                TextField("Name", text: $name).accessibilityIdentifier("vault.setup.name")
                SecureField("Vault key (16 characters)", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("vault.setup.key")
                SecureField("Type the vault key again", text: $confirm)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("vault.setup.confirm")
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").font(.wsFootnote)
                        .foregroundStyle(Tone.danger.textColor)
                }
            } header: {
                Text("Set up your vault")
            } footer: {
                Text("Exactly 16 characters, with at least one letter and one number. Write it down somewhere safe: "
                     + "nobody can recover it, not even an administrator, and without it your secrets can’t be opened.")
            }
            FeedbackSection(feedback: feedback)
            Section {
                Button {
                    Task { await create() }
                } label: {
                    if working { ProgressView() } else { Text("Create my vault") }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(working)
                .accessibilityIdentifier("vault.setup.create")
            }
        }
    }

    private func create() async {
        if let rule = VaultRules.keyProblem(key) { problem = rule; return }
        guard key == confirm else { problem = "The two keys don’t match."; return }
        problem = nil
        working = true
        defer { working = false }
        do {
            try await store.create(key: key, name: name)
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

private struct VaultUnlockForm: View {
    let store: VaultStore
    @State private var key = ""
    @State private var feedback: Feedback = .none
    @State private var working = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.vault?.string("name") ?? "Your vault").font(.wsTitle3.bold())
                    Text("\(store.vault?.int("secrets_count") ?? 0) secrets · locked").font(.wsSubheadline)
                        .foregroundStyle(.secondaryText)
                }
            }
            Section {
                SecureField("Vault key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await unlock() } }
                    .accessibilityIdentifier("vault.unlock.key")
            } footer: {
                Text("Your key stays on this phone only while the vault is open. After 5 wrong tries the vault locks for 30 minutes.")
            }
            FeedbackSection(feedback: feedback)
            Section {
                Button {
                    Task { await unlock() }
                } label: {
                    if working { ProgressView() } else { Label("Unlock", systemImage: "lock.open") }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(working || key.isEmpty)
                .accessibilityIdentifier("vault.unlock")
            }
        }
    }

    private func unlock() async {
        working = true
        defer { working = false }
        do {
            try await store.unlock(key)
            key = ""
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

private struct VaultHome: View {
    @Bindable var store: VaultStore
    @State private var feedback: Feedback = .none
    @State private var addingSecret = false
    @State private var editingFolder: VaultFolderEdit?
    @State private var deletingFolder: Record?
    @State private var changingKey = false
    @State private var showingLog = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(store.vault?.string("name") ?? "Your vault").font(.wsTitle3.bold())
                        Spacer()
                        StatusBadge(text: "Unlocked", systemImage: "lock.open", tone: .success)
                    }
                    MetricGrid(tiles: [
                        MetricTile(title: "Secrets", value: count("secrets_count", fallback: store.secrets.count)),
                        MetricTile(title: "Folders", value: count("folders_count", fallback: store.folders.count)),
                        MetricTile(title: "You’ve shared", value: count("outgoing_shares")),
                        MetricTile(title: "Shared with you", value: count("incoming_shares")),
                        MetricTile(title: "Expired", value: count("expired_secrets"),
                                   tone: (store.stats?.int("expired_secrets") ?? 0) > 0 ? .danger : .neutral),
                        MetricTile(title: "Due a new value", value: count("secrets_needing_rotation"),
                                   tone: (store.stats?.int("secrets_needing_rotation") ?? 0) > 0 ? .warning : .neutral),
                    ])
                }
                .padding(.vertical, 4)
            }
            FeedbackSection(feedback: feedback)
            if let error = store.listError {
                Section { InlineErrorRow(error: error) { Task { await store.refresh() } } }
            }
            Section {
                if store.secrets.isEmpty {
                    Text(store.search.isEmpty && store.typeFilter.isEmpty
                         ? "No secrets yet. Tap + to add a password, API key or note."
                         : "No secrets match.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(store.secrets) { secret in
                    NavigationLink {
                        VaultSecretDetail(store: store, secret: secret)
                    } label: {
                        VaultSecretRow(secret: secret)
                    }
                    .accessibilityIdentifier("vault.secret.\(secret.id)")
                }
            } header: {
                Text(store.typeFilter.isEmpty ? "Secrets" : "Secrets: \(VaultRules.typeLabel(store.typeFilter))")
            }
            Section {
                if store.folders.isEmpty {
                    Text("No folders. Folders help you group secrets.").foregroundStyle(.secondaryText)
                }
                ForEach(store.folders) { folder in
                    Button { editingFolder = VaultFolderEdit(folder: folder) } label: {
                        HStack {
                            Label(folder.string("name") ?? "Folder", systemImage: "folder")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(folder.int("secrets_count") ?? 0)").font(.wsSubheadline.monospacedDigit())
                                .foregroundStyle(.secondaryText)
                        }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { deletingFolder = folder }
                    }
                    .accessibilityIdentifier("vault.folder.\(folder.id)")
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("Tap a folder to rename it. Deleting a folder deletes the secrets in it.")
            }
            if !store.shared.isEmpty {
                Section("Shared with you") {
                    ForEach(store.shared) { share in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(share.string("secret_name") ?? "Secret").font(.wsHeadline)
                            Text(["From \(share.personName("shared_by_") ?? "someone")",
                                  VaultRules.typeLabel(share.string("secret_type")),
                                  share.string("permission") == "write" ? "can change" : "read only"]
                                .joined(separator: " · "))
                                .font(.wsSubheadline).foregroundStyle(.secondaryText)
                            if let message = share.string("message") {
                                Text("“\(message)”").font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $store.search, prompt: "Search secrets")
        .task(id: store.search) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await store.loadSecrets()
        }
        .wsRefreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Type", selection: Binding(get: { store.typeFilter }, set: { value in
                        store.typeFilter = value
                        Task { await store.loadSecrets() }
                    })) {
                        Text("All types").tag("")
                        ForEach(VaultRules.types) { Text($0.label).tag($0.value) }
                    }
                } label: {
                    Label("Type", systemImage: store.typeFilter.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                       : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("vault.filter")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { addingSecret = true } label: { Label("Add a secret", systemImage: "plus") }
                        .accessibilityIdentifier("vault.addSecret")
                    Button { editingFolder = VaultFolderEdit(folder: nil) } label: {
                        Label("Add a folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("vault.addFolder")
                    Button { showingLog = true } label: { Label("Access log", systemImage: "list.bullet.rectangle") }
                        .accessibilityIdentifier("vault.log")
                    Button { changingKey = true } label: { Label("Change vault key", systemImage: "key") }
                        .accessibilityIdentifier("vault.changeKey")
                    Button { store.lock() } label: { Label("Lock vault", systemImage: "lock") }
                        .accessibilityIdentifier("vault.lock")
                } label: {
                    Label("Vault", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("vault.menu")
            }
        }
        .navigationDestination(isPresented: $showingLog) { VaultLogView(store: store) }
        .sheet(isPresented: $addingSecret) {
            NavigationStack {
                VaultSecretForm(store: store, existing: nil, initial: VaultRules.Draft()) {
                    feedback = .done("Secret added and encrypted.")
                }
            }
        }
        .sheet(item: $editingFolder) { edit in
            NavigationStack {
                VaultFolderForm(store: store, folder: edit.folder) { message in feedback = .done(message) }
            }
        }
        .sheet(isPresented: $changingKey) {
            NavigationStack {
                VaultChangeKeyForm(store: store) { feedback = .done("Vault key changed. Every secret was encrypted again with the new key.") }
            }
        }
        .confirmationDialog("Delete this folder?", isPresented: Binding(
            get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), titleVisibility: .visible) {
            if let folder = deletingFolder {
                Button("Delete “\(folder.string("name") ?? "folder")” and its secrets", role: .destructive) {
                    Task {
                        await perform($feedback, done: "Folder deleted.") { try await store.deleteFolder(folder.id) }
                    }
                }
            }
        } message: {
            Text("The \(deletingFolder?.int("secrets_count") ?? 0) secrets in it are deleted too. This can’t be undone.")
        }
    }

    private func count(_ key: String, fallback: Int = 0) -> String {
        (store.stats?.int(key) ?? fallback).formatted()
    }
}

private struct VaultFolderEdit: Identifiable {
    let id = UUID()
    let folder: Record?
}

private struct VaultSecretRow: View {
    let secret: Record

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: VaultRules.typeSymbol(secret.string("secret_type")))
                .frame(width: 28)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(secret.string("name") ?? "Secret").font(.wsHeadline)
                Text([VaultRules.typeLabel(secret.string("secret_type")), secret.string("description")]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
                HStack(spacing: 6) {
                    if let expires = secret.date("expires_at") {
                        StatusBadge(text: expires < Date() ? "Expired" : "Expires \(Formatters.day(expires) ?? "")",
                                    systemImage: "clock", tone: expires < Date() ? .danger : .neutral)
                    }
                    if secret.bool("is_shared") == true {
                        StatusBadge(text: "Shared", systemImage: "person.2", tone: .info)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct VaultSecretDetail: View {
    let store: VaultStore
    let secret: Record
    @State private var full: Record?
    @State private var revealed = false
    @State private var shares: [Record] = []
    @State private var feedback: Feedback = .none
    @State private var working = false
    @State private var editing: VaultRules.Draft?
    @State private var sharing = false
    @State private var revoking: Record?
    @State private var copied = false

    private var shown: Record { full ?? secret }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(VaultRules.typeLabel(shown.string("secret_type")),
                          systemImage: VaultRules.typeSymbol(shown.string("secret_type")))
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    Text(shown.string("name") ?? "Secret").font(.wsTitle3.bold())
                    if let description = shown.string("description") {
                        Text(description).font(.wsBody).foregroundStyle(.secondaryText)
                    }
                }
                .padding(.vertical, 4)
            }
            FeedbackSection(feedback: feedback)
            Section {
                if revealed, let value = full?.string("value") {
                    Text(value).font(.wsBody.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("vault.secret.value")
                    Button { revealed = false } label: { Label("Hide", systemImage: "eye.slash") }
                } else {
                    Text("••••••••••••••••").font(.wsBody.monospaced()).accessibilityLabel("Hidden")
                    Button { Task { await reveal() } } label: { Label("Show value", systemImage: "eye") }
                        .disabled(working)
                        .accessibilityIdentifier("vault.secret.show")
                }
                Button { Task { await copyValue() } } label: {
                    Label(copied ? "Copied" : "Copy value", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(working)
                .accessibilityIdentifier("vault.secret.copy")
            } header: {
                Text("Value")
            } footer: {
                Text("Showing or copying the value is recorded in the vault’s access log.")
            }
            if let full {
                if full.string("metadata.username") != nil || full.string("metadata.url") != nil {
                    Section("Sign-in details") {
                        if let username = full.string("metadata.username") {
                            CopyableRow(label: "Username", value: username)
                        }
                        if let url = full.string("metadata.url") { CopyableRow(label: "Web address", value: url) }
                    }
                }
            }
            Section("Details") {
                let tags = VaultRules.tags(shown)
                if !tags.isEmpty { DetailRow(label: "Tags", value: tags.joined(separator: ", ")) }
                DetailRow(label: "Expires", value: Formatters.day(shown.date("expires_at")))
                DetailRow(label: "Reminder to change it", value: Formatters.day(shown.date("rotation_reminder_at")))
                DetailRow(label: "Value last changed", value: Formatters.dateTime(shown.date("last_rotated_at")))
                DetailRow(label: "Opened", value: shown.int("access_count").map { "\($0) times" })
                DetailRow(label: "Last opened", value: Formatters.dateTime(shown.date("last_accessed_at")))
                DetailRow(label: "Added", value: Formatters.dateTime(shown.date("created_at")))
                DetailRow(label: "Last changed", value: Formatters.dateTime(shown.date("updated_at")))
            }
            Section {
                if shares.isEmpty {
                    Text("Not shared with anyone.").foregroundStyle(.secondaryText)
                }
                ForEach(shares) { share in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(share.personName() ?? share.string("shared_with_email") ?? "Someone").font(.wsHeadline)
                            Text([share.string("shared_with_email"),
                                  share.string("permission") == "write" ? "Can change" : "Read only",
                                  share.string("status").map(Formatters.humanize)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        if share.string("status") == "active" {
                            Button("Stop", role: .destructive) { revoking = share }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("vault.share.revoke.\(share.id)")
                        }
                    }
                }
                Button { sharing = true } label: { Label("Share with someone", systemImage: "person.badge.plus") }
                    .accessibilityIdentifier("vault.secret.share")
            } header: {
                Text("Shared with")
            }
            Section {
                DeleteButton(title: "Delete secret", message: "The secret and its value are deleted. This can’t be undone.") {
                    await perform($feedback, done: "Secret deleted.") { try await store.deleteSecret(secret.id) }
                }
            }
        }
        .wsDetailList()
        .navigationTitle(shown.string("name") ?? "Secret")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadShares() }
        .wsRefreshable { await loadShares() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { Task { await startEditing() } }
                    .disabled(working)
                    .accessibilityIdentifier("vault.secret.edit")
            }
        }
        .sheet(item: Binding(get: { editing.map(VaultDraftItem.init) }, set: { if $0 == nil { editing = nil } })) { item in
            NavigationStack {
                VaultSecretForm(store: store, existing: secret, initial: item.draft) {
                    feedback = .done("Secret saved.")
                    Task { full = try? await store.secret(secret.id) }
                }
            }
        }
        .sheet(isPresented: $sharing) {
            NavigationStack {
                VaultShareForm(store: store, secret: secret) {
                    feedback = .done("Secret shared.")
                    Task { await loadShares() }
                }
            }
        }
        .confirmationDialog("Stop sharing?", isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            if let share = revoking {
                Button("Stop sharing with \(share.personName() ?? share.string("shared_with_email") ?? "them")",
                       role: .destructive) {
                    Task {
                        if await perform($feedback, done: "They can no longer see this secret.", {
                            try await store.revokeShare(share.id)
                        }) { await loadShares() }
                    }
                }
            }
        } message: {
            Text("Their copy of the secret is removed.")
        }
    }

    private func loadShares() async {
        shares = (try? await store.shares(of: secret.id)) ?? []
    }

    private func fetch() async -> Record? {
        working = true
        defer { working = false }
        do {
            let record = try await store.secret(secret.id)
            full = record
            return record
        } catch {
            feedback = .failed(error.asAPIError)
            return nil
        }
    }

    private func reveal() async {
        if await fetch() != nil { revealed = true }
    }

    private func copyValue() async {
        guard let record = await fetch(), let value = record.string("value") else { return }
        UIPasteboard.general.string = value
        copied = true
        feedback = .done("Value copied.")
    }

    private func startEditing() async {
        // Editing needs the saved sign-in details; reading them is recorded like any other read.
        let record: Record? = if let full { full } else { await fetch() }
        if let record { editing = VaultRules.Draft(record) }
    }
}

private struct VaultDraftItem: Identifiable {
    let draft: VaultRules.Draft
    var id: String { draft.name }
}

private struct VaultSecretForm: View {
    let store: VaultStore
    let existing: Record?
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VaultRules.Draft
    @State private var showValue = false
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var working = false

    init(store: VaultStore, existing: Record?, initial: VaultRules.Draft, saved: @escaping () -> Void) {
        self.store = store
        self.existing = existing
        self.saved = saved
        _draft = State(initialValue: initial)
    }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("Name (needed)", text: $draft.name).accessibilityIdentifier("vault.form.name")
                Picker("Type", selection: $draft.type) {
                    ForEach(VaultRules.types) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("vault.form.type")
                HStack {
                    Group {
                        if showValue {
                            TextField(existing == nil ? "Value (needed)" : "New value", text: $draft.value, axis: .vertical)
                        } else {
                            SecureField(existing == nil ? "Value (needed)" : "New value", text: $draft.value)
                        }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("vault.form.value")
                    Button { showValue.toggle() } label: { Image(systemName: showValue ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showValue ? "Hide value" : "Show value")
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").font(.wsFootnote)
                        .foregroundStyle(Tone.danger.textColor)
                }
            } footer: {
                if existing != nil { Text("Leave the value empty to keep the one saved.") }
            }
            Section("Sign-in details") {
                TextField("Username", text: $draft.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("vault.form.username")
                TextField("Web address", text: $draft.url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("vault.form.url")
            }
            Section {
                TextField("Description", text: $draft.description, axis: .vertical)
                    .accessibilityIdentifier("vault.form.description")
                TextField("Tags, separated by commas", text: $draft.tags)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("vault.form.tags")
            }
            Section {
                PeopleOptionalDateRow(label: "Expires", date: $draft.expiresAt)
                PeopleOptionalDateRow(label: "Remind me to change it", date: $draft.rotationAt)
            } footer: {
                Text("A date can be set or moved here, but not cleared once saved.")
            }
        }
        .navigationTitle(existing == nil ? "New secret" : "Edit secret")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(working)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(working)
                    .accessibilityIdentifier("vault.form.save")
            }
        }
    }

    private func save() async {
        if draft.name.trimmedOrNil == nil { problem = "Give the secret a name."; return }
        if existing == nil, draft.value.isEmpty { problem = "Type the value to keep safe."; return }
        problem = nil
        working = true
        defer { working = false }
        do {
            try await store.save(draft, existing: existing)
            saved()
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

private struct VaultFolderForm: View {
    let store: VaultStore
    let folder: Record?
    let saved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var colour: String
    @State private var feedback: Feedback = .none
    @State private var working = false

    init(store: VaultStore, folder: Record?, saved: @escaping (String) -> Void) {
        self.store = store
        self.folder = folder
        self.saved = saved
        _name = State(initialValue: folder?.string("name") ?? "")
        _description = State(initialValue: folder?.string("description") ?? "")
        _colour = State(initialValue: folder?.string("color") ?? "blue")
    }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("Folder name (needed)", text: $name).accessibilityIdentifier("vault.folder.name")
                TextField("Description", text: $description, axis: .vertical)
                Picker("Colour", selection: $colour) {
                    ForEach(VaultRules.folderColours) { Text($0.label).tag($0.value) }
                }
            } footer: {
                Text("Folders sit at the top level of your vault.")
            }
        }
        .navigationTitle(folder == nil ? "New folder" : "Edit folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(folder == nil ? "Add" : "Save") {
                    Task {
                        guard name.trimmedOrNil != nil else {
                            feedback = .failed(ResourceService.problem(422, "Give the folder a name."))
                            return
                        }
                        working = true
                        defer { working = false }
                        do {
                            try await store.saveFolder(existing: folder, name: name, description: description, colour: colour)
                            saved(folder == nil ? "Folder added." : "Folder saved.")
                            dismiss()
                        } catch {
                            feedback = .failed(error.asAPIError)
                        }
                    }
                }
                .disabled(working)
                .accessibilityIdentifier("vault.folder.save")
            }
        }
    }
}

private struct VaultChangeKeyForm: View {
    let store: VaultStore
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var working = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                SecureField("Current vault key", text: $current).accessibilityIdentifier("vault.key.current")
                SecureField("New vault key (16 characters)", text: $new).accessibilityIdentifier("vault.key.new")
                SecureField("Type the new key again", text: $confirm).accessibilityIdentifier("vault.key.confirm")
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").font(.wsFootnote)
                        .foregroundStyle(Tone.danger.textColor)
                }
            } footer: {
                Text("Every secret is encrypted again with the new key. The old key stops working, and people "
                     + "you’ve shared with keep their copies.")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .navigationTitle("Change vault key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Change") { Task { await change() } }
                    .disabled(working)
                    .accessibilityIdentifier("vault.key.save")
            }
        }
    }

    private func change() async {
        if let rule = VaultRules.keyProblem(new) { problem = rule; return }
        guard new == confirm else { problem = "The two new keys don’t match."; return }
        guard new != current else { problem = "The new key is the same as the current one."; return }
        problem = nil
        working = true
        defer { working = false }
        do {
            try await store.changeKey(from: current, to: new)
            changed()
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

private struct VaultShareForm: View {
    let store: VaultStore
    let secret: Record
    let shared: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var people: [Record] = []
    @State private var person: Record?
    @State private var permission = "read"
    @State private var canReshare = false
    @State private var theirKey = ""
    @State private var expiresAt: Date?
    @State private var message = ""
    @State private var feedback: Feedback = .none
    @State private var working = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                if let person {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(person.personName() ?? person.string("email") ?? "Person").font(.wsHeadline)
                            if let email = person.string("email") {
                                Text(email).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                        Spacer()
                        Button("Change") { self.person = nil }.buttonStyle(.borderless)
                    }
                } else {
                    TextField("Search by name or email", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("vault.share.search")
                    ForEach(people) { candidate in
                        Button {
                            person = candidate
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(candidate.personName() ?? candidate.string("email") ?? "Person")
                                        .foregroundStyle(.primary)
                                    Text(candidate.string("email") ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
                                }
                                Spacer()
                                if candidate.bool("has_vault") != true {
                                    Text("No vault yet").font(.wsCaption).foregroundStyle(Tone.warning.textColor)
                                }
                            }
                        }
                        .disabled(candidate.bool("has_vault") != true)
                    }
                    if people.isEmpty {
                        Text("Nobody else in this workspace matches.").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
            } header: {
                Text("Share with")
            } footer: {
                Text("Only people who have set up their own vault can receive a secret.")
            }
            Section {
                SecureField("Their vault key", text: $theirKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("vault.share.theirKey")
            } footer: {
                Text("Their copy is encrypted with their own vault key, so it’s needed once. Ask them to type it here themselves.")
            }
            Section {
                Picker("They can", selection: $permission) {
                    Text("Read it").tag("read")
                    Text("Read and change it").tag("write")
                }
                Toggle("They can share it on", isOn: $canReshare)
                PeopleOptionalDateRow(label: "Sharing ends", date: $expiresAt)
                TextField("Message (optional)", text: $message, axis: .vertical)
            }
        }
        .navigationTitle("Share secret")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            people = (try? await store.people(matching: query)) ?? []
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Share") { Task { await share() } }
                    .disabled(working || person == nil || theirKey.isEmpty)
                    .accessibilityIdentifier("vault.share.send")
            }
        }
    }

    private func share() async {
        guard let person, let userID = person.string("id") else { return }
        working = true
        defer { working = false }
        do {
            try await store.share(secret.id, with: userID, theirKey: theirKey, permission: permission,
                                  canReshare: canReshare, expiresAt: expiresAt, message: message)
            shared()
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

private struct VaultLogView: View {
    let store: VaultStore
    @State private var action = ""
    @State private var from: Date?
    @State private var to: Date?
    @State private var model: PagedListModel<Record>?
    @State private var generation = 0
    @State private var choosingDates = false

    var body: some View {
        Group {
            if let model {
                PagedList(model: model, emptyTitle: "Nothing recorded", emptySystemImage: "list.bullet.rectangle",
                          emptyDescription: "Every time the vault is opened, or a secret is added, shown, changed or shared, it’s recorded here.") { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(VaultRules.logLabel(row.string("action"))).font(.wsHeadline)
                            Spacer()
                            Text(Formatters.relative(row.date("created_at")) ?? "").font(.wsFootnote)
                                .foregroundStyle(.secondaryText)
                        }
                        if let name = row.string("secret_name") { Text(name).font(.wsSubheadline) }
                        if let detail = row.string("action_detail") {
                            Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        Text([Formatters.dateTime(row.date("created_at")), row.string("ip_address")]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
                .id(generation)
            } else {
                SkeletonList()
            }
        }
        .navigationTitle("Access log")
        .onAppear { if model == nil { rebuild() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("What happened", selection: Binding(get: { action }, set: { action = $0; rebuild() })) {
                        Text("Everything").tag("")
                        ForEach(VaultRules.logActions) { Text($0.label).tag($0.value) }
                    }
                    Button { choosingDates = true } label: { Label("Dates…", systemImage: "calendar") }
                } label: {
                    Label("Filter", systemImage: action.isEmpty && from == nil && to == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("vault.log.filter")
            }
        }
        .sheet(isPresented: $choosingDates) {
            NavigationStack {
                Form {
                    PeopleOptionalDateRow(label: "From", date: $from)
                    PeopleOptionalDateRow(label: "To", date: $to)
                }
                .navigationTitle("Dates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Show") { choosingDates = false; rebuild() }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func rebuild() {
        let action = action, from = from, to = to, store = store
        generation += 1
        model = PagedListModel { _, page in
            try await store.logs(page: page, action: action, from: from, to: to)
        }
    }
}
