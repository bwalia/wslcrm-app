import SwiftUI

// MARK: - Invitations for the signed-in person

/// A pending invitation to join a workspace, from `GET /api/v2/user/invitations`
/// (`{data: [{token, message, expires_at, namespace: {uuid, name, slug, logo_url},
/// role: {role_name, display_name}, inviter: {name}}], total}`; opsapi `routes/namespaces.lua`).
struct MyInvitation: Identifiable, Equatable, Sendable {
    let token: String
    let workspaceUuid: String?
    let workspaceName: String
    let roleName: String?
    let inviterName: String?
    let message: String?
    let expiresAt: Date?
    var id: String { token }

    init?(_ record: Record) {
        guard let token = record.string("token")?.trimmedOrNil else { return nil }
        self.token = token
        workspaceUuid = record.string("namespace.uuid")
        workspaceName = record.string("namespace.name")?.trimmedOrNil ?? "A workspace"
        roleName = record.string("role.display_name")?.trimmedOrNil
            ?? record.string("role.role_name").map { Formatters.humanize($0) }
        inviterName = record.string("inviter.name")?.trimmedOrNil
        message = record.string("message")?.trimmedOrNil
        expiresAt = record.date("expires_at")
    }

    static func list(_ json: JSONValue) -> [MyInvitation] {
        WorkspaceAPI.records(json, idKeys: ["token", "uuid"]).compactMap(MyInvitation.init)
    }

    /// "Sam Patel invited you as Site manager."
    var summary: String {
        switch (inviterName, roleName) {
        case let (who?, role?): "\(who) invited you as \(role)."
        case let (who?, nil): "\(who) invited you."
        case let (nil, role?): "You're invited as \(role)."
        default: "You're invited to join."
        }
    }
}

/// The person's workspaces as `GET /api/v2/user/namespaces` describes them: their default and
/// whether this service lets them make a new one (`can_create_workspace`; absent means no).
struct WorkspaceDirectory: Equatable, Sendable {
    var canCreate = false
    var defaultUuid: String?
    /// The person's role in each workspace, by uuid ("Owner", "Sales rep · Manager"), from `data[].roles`.
    var roles: [String: String] = [:]

    init(canCreate: Bool = false, defaultUuid: String? = nil) {
        self.canCreate = canCreate
        self.defaultUuid = defaultUuid
    }

    init(json: JSONValue) {
        let root = WorkspaceAPI.object(json)
        canCreate = root.bool("can_create_workspace") ?? false
        defaultUuid = root.string("settings.default_namespace_uuid")
        for row in WorkspaceAPI.records(json, idKeys: ["uuid"]) {
            guard let uuid = row.string("uuid") else { continue }
            let names = row.records("roles", idKeys: ["uuid", "role_name"]).compactMap {
                $0.string("display_name")?.trimmedOrNil ?? $0.string("role_name")?.trimmedOrNil
            }
            if !names.isEmpty { roles[uuid] = names.joined(separator: " · ") }
        }
    }
}

extension WorkspaceAPI {
    static let invitationsPath = "/api/v2/user/invitations"
    static let userWorkspacesPath = "/api/v2/user/namespaces"
    static let workspaceSettingsPath = "/api/v2/user/namespace-settings"

    func invitations() async throws -> [MyInvitation] {
        MyInvitation.list(try await get(Self.invitationsPath, namespace: false))
    }

    /// Joins with the signed-in account. Returns the workspace's uuid when the server names it.
    func accept(_ invitation: MyInvitation) async throws -> String? {
        let json = try await send(.post, "/api/v2/invitations/\(invitation.token)/accept", namespace: false)
        return WorkspaceAPI.object(json).string("namespace.uuid") ?? invitation.workspaceUuid
    }

    func decline(_ invitation: MyInvitation) async throws {
        try await send(.post, "/api/v2/invitations/\(invitation.token)/decline", namespace: false)
    }

    func directory() async throws -> WorkspaceDirectory {
        WorkspaceDirectory(json: try await get(Self.userWorkspacesPath, namespace: false))
    }

    /// `POST /api/v2/user/namespaces {name, description?}`: the person becomes its owner. Returns its uuid.
    func createWorkspace(name: String, description: String) async throws -> String? {
        let body = Self.createWorkspaceBody(name: name, description: description)
        let json = try await send(.post, Self.userWorkspacesPath, body: body, namespace: false)
        return WorkspaceAPI.object(json).string("namespace.uuid")
    }

    static func createWorkspaceBody(name: String, description: String) -> JSONValue {
        .fields(["name": .text(name), "description": .text(description)])
    }

    /// `PUT /api/v2/user/namespace-settings {default_namespace_id}` (the server takes a uuid or an id).
    func makeDefault(_ workspaceUuid: String) async throws {
        try await send(.put, Self.workspaceSettingsPath, body: .object(["default_namespace_id": .string(workspaceUuid)]),
                       namespace: false)
    }
}

/// The invitations waiting for the signed-in person, and what happened to the last one they answered.
@MainActor
@Observable
final class InvitationInbox {
    private(set) var items: [MyInvitation] = []
    private(set) var loadError: APIError?
    private(set) var working: String?
    var feedback: Feedback = .none

    func load(_ api: WorkspaceAPI) async {
        do {
            items = try await api.invitations()
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    /// Joins, then opens the new workspace (the session reloads the person's workspaces first).
    func accept(_ invitation: MyInvitation, api: WorkspaceAPI, session: SessionStore) async {
        working = invitation.token
        defer { working = nil }
        do {
            let uuid = try await api.accept(invitation)
            items.removeAll { $0.token == invitation.token }
            feedback = .done("You joined \(invitation.workspaceName).")
            await session.join(workspaceUuid: uuid, name: invitation.workspaceName,
                               notice: "You joined \(invitation.workspaceName).")
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            feedback = .failed(apiError)
            await load(api)
        }
    }

    func decline(_ invitation: MyInvitation, api: WorkspaceAPI) async {
        working = invitation.token
        defer { working = nil }
        do {
            try await api.decline(invitation)
            items.removeAll { $0.token == invitation.token }
            feedback = .done("Invitation declined.")
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            feedback = .failed(apiError)
            await load(api)
        }
    }
}

/// One invitation: the workspace, who asked, and Join / Decline (decline asks first).
struct InvitationCard: View {
    let invitation: MyInvitation
    let inbox: InvitationInbox
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var confirmingDecline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.open.fill")
                    .font(.wsTitle3)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Join \(invitation.workspaceName)").font(.wsHeadline)
                    Text(invitation.summary).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
            if let message = invitation.message {
                Text("“\(message)”").font(.wsSubheadline).italic()
            }
            if let expires = invitation.expiresAt {
                Text("Answer by \(expires.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 10) {
                if inbox.working == invitation.token {
                    ProgressView()
                } else {
                    Button("Join") {
                        Task { await inbox.accept(invitation, api: services.workspace(), session: session) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("invitation.accept")
                    Button("Decline", role: .destructive) { confirmingDecline = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("invitation.decline")
                }
            }
            .disabled(inbox.working != nil)
        }
        .padding(.vertical, 4)
        .confirmationDialog("Decline the invitation to \(invitation.workspaceName)?", isPresented: $confirmingDecline,
                            titleVisibility: .visible) {
            Button("Decline", role: .destructive) {
                Task { await inbox.decline(invitation, api: services.workspace()) }
            }
        } message: {
            Text("You won't join the workspace. They can invite you again later.")
        }
        .accessibilityIdentifier("invitation.\(invitation.workspaceName)")
    }
}

// MARK: - Making a workspace

/// Names a new workspace and opens it; the person becomes its owner.
struct CreateWorkspaceSheet: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var about = ""
    @State private var feedback: Feedback = .none
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                FeedbackSection(feedback: feedback)
                Section {
                    TextField("e.g. Acme Plumbing", text: $name)
                        .accessibilityIdentifier("createWorkspace.name")
                    TextField("What it's for (optional)", text: $about, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Workspace name")
                } footer: {
                    Text("A workspace keeps your company's customers, work and people together. You'll be its owner "
                         + "and can invite others once it's made.")
                }
            }
            .navigationTitle("New workspace")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(saving || name.trimmedOrNil == nil)
                        .accessibilityIdentifier("createWorkspace.save")
                }
            }
        }
    }

    private func create() async {
        saving = true
        defer { saving = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var uuid: String?
        guard await perform($feedback, done: "Made \(trimmed).", {
            uuid = try await services.workspace().createWorkspace(name: trimmed, description: about)
        }) else { return }
        dismiss()
        await session.join(workspaceUuid: uuid, name: trimmed, notice: "Your workspace \(trimmed) is ready.")
    }
}
