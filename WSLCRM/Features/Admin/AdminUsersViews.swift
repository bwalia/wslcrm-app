import SwiftUI

/// Users (`/dashboard/users`): the people who can sign in to this workspace, their accounts and roles.
/// `GET/POST /api/v2/users`, `GET/PUT/DELETE /api/v2/users/:uuid` (RBAC `users.*` in this workspace).
struct AdminUsersScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services

    var body: some View {
        if session.permissions.can(.read, moduleName: "users") {
            AdminUsersList(api: services.workspace())
        } else {
            PeopleNoAccessView(title: "Users", message: "Seeing users needs the Users permission. Ask the workspace owner to add it to your role.")
                .navigationTitle("Users")
        }
    }
}

/// The account rules the server checks (`helper/validations.lua`).
enum AdminUserRules {
    /// nil when the password is acceptable, else what to say.
    static func passwordProblem(_ password: String) -> String? {
        if password.count < 12 { return "The password needs at least 12 characters." }
        if password.count > 128 { return "The password can have at most 128 characters." }
        if password.rangeOfCharacter(from: .uppercaseLetters) == nil { return "Add a capital letter to the password." }
        if password.rangeOfCharacter(from: .lowercaseLetters) == nil { return "Add a small letter to the password." }
        if password.rangeOfCharacter(from: .decimalDigits) == nil { return "Add a number to the password." }
        return nil
    }

    static func usernameProblem(_ username: String) -> String? {
        let count = username.trimmingCharacters(in: .whitespaces).count
        return count < 3 || count > 25 ? "The username needs 3 to 25 characters." : nil
    }

    static func emailProblem(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".") ? nil : "That doesn’t look like an email address."
    }

    /// The workspace role shown for a user row (`roles: [{role_name, display_name}]`).
    static func roleLabel(_ user: Record) -> String? {
        if user.bool("is_owner") == true { return "Owner" }
        let roles = user.records("roles")
        let names = roles.compactMap { $0.string("display_name") ?? $0.string("name") ?? $0.string("role_name") }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// The body for `PUT /api/v2/users/:uuid`: only what changed (`""` clears a field).
    static func changes(from original: Record?, first: String, last: String, email: String, username: String,
                        phone: String, address: String, active: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        func put(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != (original?.string(key) ?? "") { body[key] = .string(trimmed) }
        }
        put("first_name", first)
        put("last_name", last)
        put("email", email)
        put("username", username)
        put("phone_no", phone)
        put("address", address)
        if active != (original?.bool("active") ?? false) { body["active"] = .bool(active) }
        return body
    }
}

private struct AdminUsersList: View {
    let api: WorkspaceAPI
    @Environment(SessionStore.self) private var session
    @State private var model: PagedListModel<Record>
    @State private var adding = false
    @State private var feedback: Feedback = .none

    init(api: WorkspaceAPI) {
        self.api = api
        _model = State(initialValue: PagedListModel { search, page in
            if let query = search.trimmedOrNil {
                // The list itself can't be searched on the server; this finds this workspace's people by name or email.
                let json = try await api.get("/api/v2/users/search", query: ["q": query, "limit": "50"])
                return WorkspaceAPI.page(json, page: 1, perPage: 0)
            }
            let json = try await api.get("/api/v2/users", query: ["page": String(page), "per_page": "25",
                                                                  "order_by": "first_name", "order_dir": "asc"])
            return WorkspaceAPI.page(json, page: page, perPage: 25)
        })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: "Search by name or email", emptyTitle: "No users yet",
                  emptySystemImage: "person.2",
                  emptyDescription: "People who can sign in to this workspace appear here.") { user in
            NavigationLink {
                AdminUserDetail(api: api, uuid: user.string("uuid") ?? user.id, seed: user) { Task { await model.load() } }
            } label: {
                AdminUserRow(user: user)
            }
            .accessibilityIdentifier("users.row.\(user.id)")
        }
        .safeAreaInset(edge: .top, spacing: 0) { FeedbackBar(feedback: feedback) }
        .navigationTitle("Users")
        .toolbar {
            if session.permissions.can(.create, moduleName: "users") {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add user", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("users.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                AdminUserCreateForm(api: api) { message in
                    feedback = .done(message)
                    Task { await model.load() }
                }
            }
        }
    }
}

private struct AdminUserRow: View {
    let user: Record

    var body: some View {
        HStack(spacing: 12) {
            Text(initials)
                .font(.wsSubheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Palette.tile(for: user.id), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(user.personName() ?? user.string("email") ?? "User").font(.wsHeadline)
                    if user.bool("is_owner") == true {
                        Image(systemName: "crown.fill").foregroundStyle(Tone.warning.textColor).accessibilityLabel("Owner")
                    }
                }
                Text([user.string("email"), user.string("username").map { "@\($0)" }].compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(1)
                HStack(spacing: 6) {
                    if let role = AdminUserRules.roleLabel(user) {
                        StatusBadge(text: role, systemImage: "person.badge.key", tone: .info)
                    }
                    if user.bool("active") == false {
                        StatusBadge(text: "Can’t sign in", systemImage: "nosign", tone: .neutral)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var initials: String {
        let first = user.string("first_name")?.first.map(String.init) ?? ""
        let last = user.string("last_name")?.first.map(String.init) ?? ""
        let letters = (first + last).uppercased()
        return letters.isEmpty ? String((user.string("email") ?? "?").prefix(1)).uppercased() : letters
    }
}

private struct AdminUserDetail: View {
    let api: WorkspaceAPI
    let uuid: String
    let seed: Record
    let changed: () -> Void
    @Environment(SessionStore.self) private var session
    @State private var user: Record?
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var editing = false
    @State private var changingRoles = false

    private var shown: Record { user ?? seed }
    private var isSelf: Bool { session.user?.uuid == uuid }

    var body: some View {
        List {
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.personName() ?? shown.string("email") ?? "User").font(.wsTitle3.bold())
                    if let email = shown.string("email") { Text(email).font(.wsSubheadline).foregroundStyle(.secondaryText) }
                    HStack(spacing: 6) {
                        StatusBadge(text: shown.bool("active") == false ? "Can’t sign in" : "Can sign in",
                                    systemImage: shown.bool("active") == false ? "nosign" : "checkmark.circle",
                                    tone: shown.bool("active") == false ? .neutral : .success)
                        if let role = AdminUserRules.roleLabel(seed) {
                            StatusBadge(text: role, systemImage: "person.badge.key", tone: .info)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            FeedbackSection(feedback: feedback)
            Section("Account") {
                DetailRow(label: "Username", value: shown.string("username"))
                if let email = shown.string("email") { EmailLinkRow(email: email) }
                if let phone = shown.string("phone_no") { PhoneLinkRow(name: "Phone", phone: phone) }
                DetailRow(label: "Address", value: shown.string("address"))
                DetailRow(label: "Signs in with", value: shown.string("oauth_provider").map(Formatters.humanize))
                DetailRow(label: "Member since", value: Formatters.day(shown.date("created_at")))
                DetailRow(label: "Last updated", value: Formatters.dateTime(shown.date("updated_at")))
            }
            let platformRoles = shown.records("roles").compactMap { $0.string("role_name") ?? $0.string("name") }
            if user != nil, !platformRoles.isEmpty {
                Section {
                    ForEach(platformRoles, id: \.self) { role in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Formatters.humanize(role)).font(.wsBody)
                            if let about = Self.platformRoleText[role] {
                                Text(about).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                } header: {
                    Text("Platform roles")
                } footer: {
                    Text("Account-wide roles, separate from roles in a workspace.")
                }
            }
            let workspaces = shown.records("namespaces")
            if !workspaces.isEmpty {
                Section("Workspaces") {
                    ForEach(workspaces) { space in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(space.string("namespace_name") ?? "Workspace").font(.wsHeadline)
                                if space.bool("is_owner") == true {
                                    Image(systemName: "crown.fill").foregroundStyle(Tone.warning.textColor)
                                        .accessibilityLabel("Owner")
                                }
                            }
                            Text([space.string("namespace_slug").map { "@\($0)" },
                                  space.records("roles").compactMap { $0.string("display_name") ?? $0.string("role_name") }
                                      .joined(separator: ", ").trimmedOrNil,
                                  space.string("membership_status").map(Formatters.humanize)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            let canUpdate = session.permissions.can(.update, moduleName: "users")
            if canUpdate {
                Section {
                    Button { editing = true } label: { Label("Edit account", systemImage: "pencil") }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("users.edit")
                    if membership != nil, !isOwnerHere {
                        Button { changingRoles = true } label: { Label("Change workspace roles", systemImage: "person.badge.key") }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("users.roles")
                    } else if isOwnerHere {
                        Label("Owner — full access", systemImage: "crown").foregroundStyle(.secondaryText)
                    }
                }
            }
            if session.permissions.can(.delete, moduleName: "users"), !isSelf {
                Section {
                    DeleteButton(title: "Delete account",
                                 message: "This deletes \(shown.personName() ?? "this person")’s account everywhere, not just "
                                     + "in this workspace. They can no longer sign in. This can’t be undone.") {
                        await perform($feedback, done: "Account deleted.") {
                            try await api.send(.delete, "/api/v2/users/\(uuid)")
                            changed()
                        }
                    }
                } footer: {
                    Text("To take someone out of this workspace only, remove them from the workspace’s members instead.")
                }
            }
        }
        .navigationTitle(shown.personName() ?? "User")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                AdminUserEditForm(api: api, user: shown) {
                    feedback = .done("Account saved.")
                    changed()
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $changingRoles) {
            if let membership {
                MemberRolesSheet(memberID: membership.id, currentRoleIDs: membership.roleIDs) {
                    feedback = .done("Workspace roles changed. They’ll need to sign in again to see the change.")
                    changed()
                    Task { await load() }
                }
            }
        }
    }

    private struct Membership {
        let id: String
        let roleIDs: Set<Int>
    }

    /// Their membership of this workspace: from the list row, else from the detailed account.
    private var membership: Membership? {
        if let id = seed.string("member_uuid") {
            return Membership(id: id, roleIDs: Set(seed.records("roles").compactMap { $0.int("id") }))
        }
        let current = session.workspace?.uuid
        guard let space = shown.records("namespaces").first(where: { $0.string("namespace_uuid") == current }),
              let id = space.string("membership_uuid") else { return nil }
        return Membership(id: id, roleIDs: Set(space.records("roles").compactMap { $0.int("id") }))
    }

    private var isOwnerHere: Bool {
        if seed.bool("is_owner") == true { return true }
        let current = session.workspace?.uuid
        return shown.records("namespaces").first { $0.string("namespace_uuid") == current }?.bool("is_owner") == true
    }

    private static let platformRoleText: [String: String] = [
        "administrative": "Platform administrator: full access to every workspace.",
        "admin": "Administrator.",
        "seller": "Can sell in the shop.",
        "buyer": "A customer account.",
        "delivery_partner": "Delivers orders.",
    ]

    private func load() async {
        do {
            let json = try await api.get("/api/v2/users/\(uuid)", query: ["detailed": "true"])
            user = WorkspaceAPI.record(json)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }
}

private struct AdminUserCreateForm: View {
    let api: WorkspaceAPI
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var last = ""
    @State private var email = ""
    @State private var username = ""
    @State private var role = "member"
    @State private var roles: [PeopleRoles.Option] = []
    @State private var password = ""
    @State private var showPassword = false
    @State private var phone = ""
    @State private var address = ""
    @State private var canSignIn = true
    @State private var problems: [String: String] = [:]
    @State private var feedback: Feedback = .none
    @State private var working = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section("Who") {
                field("First name (needed)", $first, key: "first_name")
                field("Last name (needed)", $last, key: "last_name")
                field("Email (needed)", $email, key: "email", keyboard: .emailAddress)
                field("Username (needed)", $username, key: "username")
            }
            Section {
                Picker("Workspace role", selection: $role) {
                    if roles.isEmpty { Text("Member").tag("member") }
                    ForEach(roles) { Text($0.label).tag($0.name) }
                }
                .accessibilityIdentifier("users.new.role")
            } footer: {
                Text("What they can do in this workspace. You can only give a role whose permissions you have yourself.")
            }
            Section {
                HStack {
                    Group {
                        if showPassword { TextField("Password (needed)", text: $password) }
                        else { SecureField("Password (needed)", text: $password) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("users.new.password")
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
                problem("password")
                Toggle("They can sign in straight away", isOn: $canSignIn)
            } header: {
                Text("Password")
            } footer: {
                Text("At least 12 characters with a capital letter, a small letter and a number. Passwords found in "
                     + "known data breaches are refused. Give it to them yourself: it isn’t emailed.")
            }
            Section("Contact (optional)") {
                field("Phone", $phone, key: "phone_no", keyboard: .phonePad)
                TextField("Address", text: $address, axis: .vertical)
            }
        }
        .navigationTitle("Add user")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(working)
        .task { roles = (try? await PeopleRoles.load(api)) ?? [] }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save() } }
                    .disabled(working)
                    .accessibilityIdentifier("users.new.save")
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ text: Binding<String>, key: String, keyboard: UIKeyboardType = .default) -> some View {
        TextField(label, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(keyboard == .default && key.hasSuffix("name") ? .words : .never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("users.new.\(key)")
        problem(key)
    }

    @ViewBuilder
    private func problem(_ key: String) -> some View {
        if let message = problems[key] {
            Label(message, systemImage: "exclamationmark.circle").font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
        }
    }

    private func save() async {
        var found: [String: String] = [:]
        if first.trimmedOrNil == nil { found["first_name"] = "Add their first name." }
        if last.trimmedOrNil == nil { found["last_name"] = "Add their last name." }
        if let issue = AdminUserRules.emailProblem(email) { found["email"] = issue }
        if let issue = AdminUserRules.usernameProblem(username) { found["username"] = issue }
        if let issue = AdminUserRules.passwordProblem(password) { found["password"] = issue }
        problems = found
        guard found.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let body = JSONValue.fields([
                "first_name": .text(first), "last_name": .text(last), "email": .text(email),
                "username": .text(username), "password": .string(password), "namespace_role": .string(role),
            ])
            let json = try await api.send(.post, "/api/v2/users", body: body)
            // The server leaves new accounts switched off and ignores contact details on create:
            // a follow-up save switches the account on and adds them.
            if let user = WorkspaceAPI.record(json), let uuid = user.string("uuid") ?? user.string("id") {
                var follow: [String: JSONValue] = [:]
                if canSignIn, user.bool("active") != true { follow["active"] = .bool(true) }
                if let phone = phone.trimmedOrNil { follow["phone_no"] = .string(phone) }
                if let address = address.trimmedOrNil { follow["address"] = .string(address) }
                if !follow.isEmpty {
                    do {
                        try await api.send(.put, "/api/v2/users/\(uuid)", body: .object(follow))
                    } catch {
                        created("Account added, but it couldn’t be switched on or given its contact details: "
                                + error.asAPIError.localizedDescription + " Open the account to try again.")
                        dismiss()
                        return
                    }
                }
            }
            created(canSignIn ? "Account added. They can sign in now with the password you set."
                              : "Account added. It stays switched off until you turn on “Can sign in”.")
            dismiss()
        } catch {
            let apiError = error.asAPIError
            if let server = apiError.serverError, server.status >= 500,
               server.message.lowercased().contains("create user") {
                // The server reports a weak or breached password as a general failure.
                feedback = .failed(ResourceService.problem(422, "The account couldn’t be added. The most common reason is "
                    + "a password found in a known data breach, or an email or username already in use. Try another password."))
            } else {
                feedback = .failed(apiError)
            }
        }
    }
}

private struct AdminUserEditForm: View {
    let api: WorkspaceAPI
    let user: Record
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var first: String
    @State private var last: String
    @State private var email: String
    @State private var username: String
    @State private var phone: String
    @State private var address: String
    @State private var active: Bool
    @State private var problems: [String: String] = [:]
    @State private var feedback: Feedback = .none
    @State private var working = false

    init(api: WorkspaceAPI, user: Record, saved: @escaping () -> Void) {
        self.api = api
        self.user = user
        self.saved = saved
        _first = State(initialValue: user.string("first_name") ?? "")
        _last = State(initialValue: user.string("last_name") ?? "")
        _email = State(initialValue: user.string("email") ?? "")
        _username = State(initialValue: user.string("username") ?? "")
        _phone = State(initialValue: user.string("phone_no") ?? "")
        _address = State(initialValue: user.string("address") ?? "")
        _active = State(initialValue: user.bool("active") ?? true)
    }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section("Who") {
                TextField("First name", text: $first).accessibilityIdentifier("users.edit.first_name")
                TextField("Last name", text: $last).accessibilityIdentifier("users.edit.last_name")
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("users.edit.email")
                if let issue = problems["email"] { problemLabel(issue) }
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("users.edit.username")
                if let issue = problems["username"] { problemLabel(issue) }
            }
            Section("Contact") {
                TextField("Phone", text: $phone).keyboardType(.phonePad).accessibilityIdentifier("users.edit.phone")
                TextField("Address", text: $address, axis: .vertical).accessibilityIdentifier("users.edit.address")
            }
            Section {
                Toggle("Can sign in", isOn: $active).accessibilityIdentifier("users.edit.active")
            } footer: {
                Text("Turn this off to stop them signing in without deleting the account. Changing the email, "
                     + "username or this switch for someone who also belongs to another workspace needs a platform administrator.")
            }
        }
        .navigationTitle("Edit account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(working)
                    .accessibilityIdentifier("users.edit.save")
            }
        }
    }

    private func problemLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle").font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
    }

    private func save() async {
        var found: [String: String] = [:]
        if let issue = AdminUserRules.emailProblem(email) { found["email"] = issue }
        if let issue = AdminUserRules.usernameProblem(username) { found["username"] = issue }
        problems = found
        guard found.isEmpty else { return }
        let body = AdminUserRules.changes(from: user, first: first, last: last, email: email, username: username,
                                         phone: phone, address: address, active: active)
        guard !body.isEmpty, let uuid = user.string("uuid") ?? user.string("id") else { dismiss(); return }
        working = true
        defer { working = false }
        do {
            try await api.send(.put, "/api/v2/users/\(uuid)", body: .object(body))
            saved()
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}
