import SwiftUI

/// The signed-in person's own account (the web's Settings page): their details, password, the
/// workspace's sign-in code rule, their API keys, this device's app settings, and closing the account.
struct AccountSettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var security: Record?

    var body: some View {
        List {
            if let user = session.user {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.displayName).font(.wsTitle3.bold())
                        Text(user.email).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    NavigationLink {
                        AccountProfileView()
                    } label: {
                        Label("Your details", systemImage: "person.text.rectangle")
                    }
                    .accessibilityIdentifier("account.profile")
                }
            }
            Section {
                NavigationLink {
                    AccountPasswordView()
                } label: {
                    Label("Change password", systemImage: "key")
                }
                .accessibilityIdentifier("account.password")
                if let security {
                    let on = security.bool("mfa_required") ?? true
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Sign-in code: \(on ? "On" : "Off")", systemImage: on ? "lock.shield" : "lock.open")
                        Text(on ? "Everyone in this workspace gets a code by email when they sign in."
                                : "Members of this workspace sign in with their password only.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    if security.bool("can_change") == true {
                        NavigationLink(value: NativeScreenRoute(WorkspaceScreen.settings)) {
                            Label("Change it in workspace settings", systemImage: "slider.horizontal.3")
                        }
                        .accessibilityIdentifier("account.mfaSettings")
                    }
                }
            } header: {
                Text("Signing in")
            } footer: {
                Text("The sign-in code is set for the whole workspace by its owner.")
            }
            Section {
                NavigationLink(value: NativeScreenRoute(WorkspaceScreen.personalAPIKeys)) {
                    Label("My API keys", systemImage: "key.horizontal")
                }
                .accessibilityIdentifier("account.apiKeys")
            } footer: {
                Text("Keys that let an AI agent, a script or your website work as you.")
            }
            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("App settings", systemImage: "iphone")
                }
                .accessibilityIdentifier("account.appSettings")
            } footer: {
                Text("Face ID, permissions and the app version, on this device.")
            }
            Section {
                NavigationLink {
                    AccountDeleteView()
                } label: {
                    Label("Delete my account", systemImage: "person.crop.circle.badge.xmark")
                        .foregroundStyle(Tone.danger.textColor)
                }
                .accessibilityIdentifier("account.delete")
            }
        }
        .navigationTitle("Account")
        .task {
            if let json = try? await services.workspace().get("/api/v2/namespace/security") {
                security = WorkspaceAPI.record(json)
            }
        }
    }
}

/// The person's name, email, phone and address (`PUT /api/v2/users/:uuid`).
struct AccountProfileView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var address = ""
    @State private var original: [String] = []
    @State private var loaded = false
    @State private var feedback: Feedback = .none
    @State private var saving = false

    static func body(firstName: String, lastName: String, email: String, phone: String, address: String) -> JSONValue {
        .object([
            "first_name": .textOrEmpty(firstName), "last_name": .textOrEmpty(lastName),
            "email": .textOrEmpty(email), "phone_no": .textOrEmpty(phone), "address": .textOrEmpty(address),
        ])
    }

    /// The server's 403 in words that say what to do.
    static func explain(_ error: APIError) -> APIError {
        if case .forbidden = error {
            return ResourceService.problem(403, "Changing your details needs the Users update permission in this workspace. Ask the workspace owner to change them, or to give you that permission.")
        }
        return error
    }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                    .accessibilityIdentifier("account.firstName")
                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
                    .accessibilityIdentifier("account.lastName")
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("account.email")
                TextField("Phone", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .accessibilityIdentifier("account.phone")
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...4)
                    .textContentType(.fullStreetAddress)
                    .accessibilityIdentifier("account.address")
            } footer: {
                Text("Your email is also what you sign in with.")
            }
        }
        .navigationTitle("Your details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || !loaded || current == original)
                    .accessibilityIdentifier("account.save")
            }
        }
        .task { await load() }
    }

    private var current: [String] { [firstName, lastName, email, phone, address] }

    private func load() async {
        guard !loaded, let user = session.user else { return }
        firstName = user.firstName
        lastName = user.lastName
        email = user.email
        if let json = try? await services.workspace().get("/api/v2/users/\(user.uuid)"),
           let record = WorkspaceAPI.record(json) {
            firstName = record.string("first_name") ?? firstName
            lastName = record.string("last_name") ?? lastName
            email = record.string("email") ?? email
            phone = record.string("phone_no") ?? ""
            address = record.string("address") ?? ""
        }
        original = current
        loaded = true
    }

    private func save() async {
        guard let user = session.user else { return }
        if !email.contains("@") {
            feedback = .failed(ResourceService.problem(422, "That email doesn’t look right."))
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await services.workspace().send(.put, "/api/v2/users/\(user.uuid)",
                                                body: Self.body(firstName: firstName, lastName: lastName, email: email,
                                                                phone: phone, address: address))
            original = current
            feedback = .done("Saved. Your new details show everywhere the next time you sign in.")
        } catch {
            feedback = .failed(Self.explain(error.asAPIError))
        }
    }
}

/// Change password (`POST /auth/change-password`). Every session ends, so the person signs in again.
struct AccountPasswordView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var problem: String?
    @State private var error: APIError?
    @State private var saving = false
    @State private var changed = false

    /// What's wrong with the passwords typed, in plain words; nil when they can be sent.
    static func problem(current: String, new: String, confirm: String) -> String? {
        if current.isEmpty { return "Type your current password." }
        if new.count < 8 { return "The new password must be at least 8 characters." }
        if new.count > 256 { return "The new password is too long." }
        if new != confirm { return "The two new passwords don’t match." }
        return nil
    }

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                SecureField("Current password", text: $current)
                    .textContentType(.password)
                    .accessibilityIdentifier("password.current")
            }
            Section {
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("password.new")
                SecureField("New password again", text: $confirm)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("password.confirm")
            } footer: {
                Text("At least 8 characters. Afterwards you’re signed out everywhere, including here, and sign in again with the new password.")
            }
            Section {
                Button(saving ? "Changing…" : "Change password") { Task { await save() } }
                    .disabled(saving)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("password.save")
            }
        }
        .navigationTitle("Change password")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Password changed", isPresented: $changed) {
            Button("Sign in again") { Task { await session.signOut() } }
        } message: {
            Text("You’ve been signed out everywhere. Sign in with your new password.")
        }
    }

    private func save() async {
        problem = Self.problem(current: current, new: newPassword, confirm: confirm)
        guard problem == nil else { return }
        saving = true
        defer { saving = false }
        do {
            try await services.workspace().send(.post, "/auth/change-password",
                                                body: .object(["current_password": .string(current),
                                                               "new_password": .string(newPassword)]),
                                                namespace: false)
            error = nil
            changed = true
        } catch {
            let apiError = error.asAPIError
            if let server = apiError.serverError, let reason = server.fieldErrors["new_password"] {
                problem = reason == "too_short" ? "The new password must be at least 8 characters."
                    : reason == "too_long" ? "The new password is too long." : "Type a new password."
            } else if apiError.serverError?.fieldErrors["current_password"] != nil {
                problem = "Type your current password."
            } else {
                self.error = apiError
            }
        }
    }
}

/// Close the account (`POST /auth/delete-account`): it is deactivated and every session ends.
struct AccountDeleteView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var password = ""
    @State private var confirming = false
    @State private var error: APIError?
    @State private var working = false
    @State private var doneMessage: String?

    var body: some View {
        Form {
            Section {
                Label("Your account is deactivated: you can’t sign in to any workspace, and every device is signed out. Contact support to have your data deleted for good.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.warning.textColor)
            }
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                SecureField("Your password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("deleteAccount.password")
            } footer: {
                Text("To make sure it’s you. If you signed in with Google or Apple in the last 10 minutes you can leave it empty.")
            }
            Section {
                Button(working ? "Deleting…" : "Delete my account", role: .destructive) { confirming = true }
                    .disabled(working)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("deleteAccount.submit")
            }
        }
        .navigationTitle("Delete my account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete your account?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete my account", role: .destructive) { Task { await delete() } }
        } message: {
            Text("You’ll be signed out everywhere and can’t sign in again.")
        }
        .alert("Account deleted", isPresented: Binding(get: { doneMessage != nil }, set: { if !$0 { doneMessage = nil } })) {
            Button("OK") { Task { await session.signOut() } }
        } message: {
            Text(doneMessage ?? "")
        }
    }

    private func delete() async {
        working = true
        defer { working = false }
        do {
            var body: [String: JSONValue] = [:]
            if !password.isEmpty { body["password"] = .string(password) }
            let json = try await services.workspace().send(.post, "/auth/delete-account", body: .object(body), namespace: false)
            error = nil
            doneMessage = WorkspaceAPI.object(json).string("message")
                ?? "Your account has been deactivated. Contact support to permanently delete your data."
        } catch {
            let apiError = error.asAPIError
            switch apiError.serverError?.code {
            case "password_incorrect":
                self.error = ResourceService.problem(403, "That password isn’t right. Try again.")
            case "reauth_required":
                self.error = ResourceService.problem(403, "Type your password to confirm it’s you.")
            default:
                self.error = apiError
            }
        }
    }
}
