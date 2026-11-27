import SwiftUI

/// A member of a workspace, from either shape OpsAPI sends: the list's (`user: {…}`, `roles`) or a
/// single member's flat one (`email`, `first_name`, `user_uuid`, `roles`).
struct WorkspaceMember: Identifiable, Hashable, Sendable {
    let id: String
    let userUUID: String?
    let name: String
    let email: String?
    let username: String?
    let status: String
    let isOwner: Bool
    let joinedAt: Date?
    let invitedBy: String?
    let roles: [Role]

    struct Role: Hashable, Sendable {
        let id: Int?
        let name: String
    }

    init(_ record: Record) {
        id = record.string("uuid") ?? record.id
        userUUID = record.string("user.uuid") ?? record.string("user_uuid")
        email = record.string("user.email") ?? record.string("email")
        username = record.string("user.username") ?? record.string("username")
        name = record.personName("user.") ?? record.personName() ?? email ?? "Member"
        status = record.string("status") ?? "active"
        isOwner = record.bool("is_owner") ?? false
        joinedAt = record.date("joined_at")
        invitedBy = record.string("invited_by_name")
        roles = record.records("roles").map { role in
            Role(id: role.int("id"), name: role.string("display_name") ?? role.string("role_name").map(Formatters.humanize) ?? "Role")
        }
    }

    var roleIDs: Set<Int> { Set(roles.compactMap(\.id)) }

    var roleSummary: String {
        if isOwner { return "Owner" }
        return roles.isEmpty ? "No roles" : roles.map(\.name).joined(separator: ", ")
    }

    static let statusStyle = StatusStyle(tones: ["active": .success, "invited": .warning, "suspended": .danger,
                                                 "left": .neutral, "removed": .neutral],
                                         labels: ["left": "Left"])
}

/// An invitation to join the workspace (`GET /api/v2/namespace/invitations` rows).
struct WorkspaceInvitation: Identifiable, Hashable, Sendable {
    let id: String
    let email: String
    let role: String?
    let message: String?
    let inviter: String?
    let expiresAt: Date?
    let createdAt: Date?
    let rawStatus: String

    init(_ record: Record) {
        id = record.string("uuid") ?? record.id
        email = record.string("email") ?? "—"
        role = record.string("role.display_name") ?? record.string("role.role_name").map(Formatters.humanize)
        message = record.string("message")
        inviter = record.string("inviter.name") ?? record.string("inviter.email")
        expiresAt = record.date("expires_at")
        createdAt = record.date("created_at")
        rawStatus = record.string("status") ?? "pending"
    }

    /// A pending invitation past its date has expired, whatever the row says.
    func status(now: Date = Date()) -> String {
        if rawStatus == "pending", let expiresAt, expiresAt < now { return "expired" }
        return rawStatus
    }

    func canResend(now: Date = Date()) -> Bool { ["pending", "expired"].contains(status(now: now)) }
    func canRevoke(now: Date = Date()) -> Bool { status(now: now) == "pending" }

    /// `POST /api/v2/namespace/invitations` (`role_id` left out for the default role).
    static func body(email: String, roleID: Int?, message: String, days: Int) -> JSONValue {
        .fields([
            "email": .string(email.trimmingCharacters(in: .whitespaces).lowercased()),
            "role_id": .intIfAny(roleID),
            "message": .text(message),
            "expires_in_days": .intIfAny(days),
        ])
    }

    static let statusStyle = StatusStyle(tones: ["pending": .warning, "accepted": .success, "declined": .neutral,
                                                 "expired": .danger, "revoked": .neutral],
                                         symbols: ["pending": "clock"])
}

/// The workspace's members and invitations (`/dashboard/namespace/members`). `target`: another
/// workspace a platform admin is managing; every call then goes to it.
struct WorkspaceMembersView: View {
    var target: WorkspaceTarget?
    @Environment(\.services) private var services

    var body: some View {
        WorkspaceMembersContent(target: target, api: services.workspace(target))
    }
}

private enum WorkspaceMembersTab: String, CaseIterable, Identifiable, Hashable {
    case members, invitations
    var id: String { rawValue }
    var title: String { self == .members ? "Members" : "Invitations" }
}

private struct WorkspaceMembersContent: View {
    let target: WorkspaceTarget?
    let api: WorkspaceAPI
    @Environment(SessionStore.self) private var session
    @State private var tab: WorkspaceMembersTab = .members
    @State private var memberStatus = ""
    @State private var invitationStatus = ""
    @State private var members: PagedListModel<Record>
    @State private var invitations: PagedListModel<Record>
    @State private var filters = WorkspaceMemberFilters()
    @State private var inviting = false
    @State private var adding = false
    @State private var chosenInvitation: WorkspaceInvitation?
    @State private var revokingInvitation: WorkspaceInvitation?
    @State private var feedback: Feedback = .none
    @State private var hasAppeared = false

    init(target: WorkspaceTarget?, api: WorkspaceAPI) {
        self.target = target
        self.api = api
        let filters = WorkspaceMemberFilters()
        _filters = State(initialValue: filters)
        _members = State(initialValue: PagedListModel { search, page in
            let json = try await api.get("/api/v2/namespace/members", query: [
                "page": String(page), "per_page": "25", "search": search,
                "status": filters.memberStatus.isEmpty ? nil : filters.memberStatus,
            ])
            return WorkspaceAPI.page(json, page: page, perPage: 25)
        })
        _invitations = State(initialValue: PagedListModel { search, page in
            let json = try await api.get("/api/v2/namespace/invitations", query: [
                "page": String(page), "per_page": "25", "search": search,
                "status": filters.invitationStatus.isEmpty ? nil : filters.invitationStatus,
            ])
            return WorkspaceAPI.page(json, page: page, perPage: 25)
        })
    }

    private var canCreate: Bool { session.permissions.can(.create, moduleName: "users") }
    private var canDelete: Bool { session.permissions.can(.delete, moduleName: "users") }

    var body: some View {
        Group {
            switch tab {
            case .members: membersList
            case .invitations: invitationsList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                SectionTabs(tabs: WorkspaceMembersTab.allCases, selection: $tab) { $0.title }
                FeedbackBar(feedback: feedback)
            }
        }
        .navigationTitle(target.map { "Members of \($0.name)" } ?? "Members")
        .onAppear {
            if hasAppeared { Task { await members.load() } }
            hasAppeared = true
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { inviting = true } label: { Label("Invite by email", systemImage: "envelope") }
                            .accessibilityIdentifier("members.invite")
                        Button { adding = true } label: {
                            Label("Add someone who already has an account", systemImage: "person.badge.plus")
                        }
                        .accessibilityIdentifier("members.addExisting")
                    } label: {
                        Label("Add people", systemImage: "plus")
                    }
                    .accessibilityIdentifier("members.add")
                }
            }
        }
        .sheet(isPresented: $inviting) {
            NavigationStack {
                WorkspaceInviteForm(api: api) { email, days in
                    feedback = .done("Invitation sent to \(email). It lasts \(days) day\(days == 1 ? "" : "s").")
                    tab = .invitations
                    Task { await invitations.load() }
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                WorkspaceAddExistingForm(api: api) { email in
                    feedback = .done("\(email) is now a member.")
                    tab = .members
                    Task { await members.load() }
                }
            }
        }
        .confirmationDialog(chosenInvitation?.email ?? "", isPresented: Binding(
            get: { chosenInvitation != nil }, set: { if !$0 { chosenInvitation = nil } }), titleVisibility: .visible) {
            if let invitation = chosenInvitation {
                if canCreate, invitation.canResend() {
                    Button("Send it again") { Task { await resend(invitation) } }
                }
                if canDelete, invitation.canRevoke() {
                    Button("Cancel the invitation", role: .destructive) { Task { await revoke(invitation) } }
                }
            }
        } message: {
            if let invitation = chosenInvitation {
                Text(invitation.canRevoke() ? "Sending again gives them a fresh link that lasts 7 days. Cancelling stops the link working."
                     : "Sending again gives them a fresh link that lasts 7 days.")
            }
        }
        .confirmationDialog("Cancel the invitation to \(revokingInvitation?.email ?? "them")?", isPresented: Binding(
            get: { revokingInvitation != nil }, set: { if !$0 { revokingInvitation = nil } }), titleVisibility: .visible) {
            if let invitation = revokingInvitation {
                Button("Cancel the invitation", role: .destructive) { Task { await revoke(invitation) } }
                Button("Keep it", role: .cancel) {}
            }
        } message: {
            Text("The link in their email stops working. You can invite them again later.")
        }
    }

    private var membersList: some View {
        PagedList(model: members, searchPrompt: "Search by name or email", emptyTitle: "No members found",
                  emptySystemImage: "person.2",
                  emptyDescription: memberStatus.isEmpty ? "Invite people to work in this workspace."
                      : "Nobody here has that status.",
                  emptyActionTitle: "Invite someone",
                  emptyAction: canCreate && memberStatus.isEmpty ? { inviting = true } : nil) { record in
            let member = WorkspaceMember(record)
            NavigationLink {
                WorkspaceMemberDetailView(member: member, target: target, api: api) {
                    Task { await members.load() }
                }
            } label: {
                WorkspaceMemberRow(member: member, isYou: member.userUUID == session.user?.uuid && target == nil)
            }
            .accessibilityIdentifier("members.row.\(member.id)")
        }
    }

    private var invitationsList: some View {
        PagedList(model: invitations, searchPrompt: "Search by email", emptyTitle: "No invitations",
                  emptySystemImage: "envelope.open",
                  emptyDescription: "Invitations you send by email show here until they’re accepted.",
                  emptyActionTitle: "Invite someone",
                  emptyAction: canCreate && invitationStatus.isEmpty ? { inviting = true } : nil) { record in
            let invitation = WorkspaceInvitation(record)
            Button {
                if (canCreate && invitation.canResend()) || (canDelete && invitation.canRevoke()) {
                    chosenInvitation = invitation
                }
            } label: {
                WorkspaceInvitationRow(invitation: invitation)
            }
            .foregroundStyle(.primary)
            .swipeActions(allowsFullSwipe: false) {
                if canDelete, invitation.canRevoke() {
                    Button("Cancel", role: .destructive) { revokingInvitation = invitation }
                }
                if canCreate, invitation.canResend() {
                    Button("Send again") { Task { await resend(invitation) } }.tint(.accentColor)
                }
            }
            .accessibilityIdentifier("invitations.row.\(invitation.id)")
        }
    }

    private var filterMenu: some View {
        Menu {
            if tab == .members {
                Picker("Status", selection: Binding(get: { memberStatus }, set: { value in
                    memberStatus = value
                    filters.memberStatus = value
                    Task { await members.load() }
                })) {
                    Text("Everyone").tag("")
                    Text("Active").tag("active")
                    Text("Invited").tag("invited")
                    Text("Suspended").tag("suspended")
                }
            } else {
                Picker("Status", selection: Binding(get: { invitationStatus }, set: { value in
                    invitationStatus = value
                    filters.invitationStatus = value
                    Task { await invitations.load() }
                })) {
                    Text("All").tag("")
                    Text("Pending").tag("pending")
                    Text("Accepted").tag("accepted")
                    Text("Expired").tag("expired")
                    Text("Cancelled").tag("revoked")
                }
            }
        } label: {
            let active = tab == .members ? !memberStatus.isEmpty : !invitationStatus.isEmpty
            Label("Filter", systemImage: active ? "line.3.horizontal.decrease.circle.fill"
                                                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("members.filter")
    }

    private func resend(_ invitation: WorkspaceInvitation) async {
        await perform($feedback, done: "A fresh invitation was sent to \(invitation.email).") {
            try await api.send(.post, "/api/v2/namespace/invitations/\(invitation.id)/resend")
        }
        await invitations.load()
    }

    private func revoke(_ invitation: WorkspaceInvitation) async {
        await perform($feedback, done: "The invitation to \(invitation.email) was cancelled. Its link no longer works.") {
            try await api.send(.delete, "/api/v2/namespace/invitations/\(invitation.id)")
        }
        await invitations.load()
    }
}

/// The list filters, read when a page is fetched.
@MainActor
private final class WorkspaceMemberFilters {
    var memberStatus = ""
    var invitationStatus = ""
}

private struct WorkspaceMemberRow: View {
    let member: WorkspaceMember
    let isYou: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(member.name).font(.wsHeadline).lineLimit(2)
                    if member.isOwner {
                        Image(systemName: "crown.fill").foregroundStyle(Tone.brand.textColor).accessibilityLabel("Owner")
                    }
                    if isYou { Text("You").font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText) }
                }
                if let email = member.email, email != member.name {
                    Text(email).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(1)
                }
                Text(member.roleSummary).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 8)
            let style = WorkspaceMember.statusStyle
            StatusBadge(text: style.label(for: member.status), systemImage: style.symbol(for: member.status),
                        tone: style.tone(for: member.status))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceInvitationRow: View {
    let invitation: WorkspaceInvitation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(invitation.email).font(.wsHeadline).lineLimit(1)
                Text(invitation.role ?? "The default role").font(.wsSubheadline).foregroundStyle(.secondaryText)
                let parts = [invitation.inviter.map { "Invited by \($0)" },
                             Formatters.day(invitation.expiresAt).map { "Link lasts until \($0)" }].compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            Spacer(minLength: 8)
            let status = invitation.status()
            let style = WorkspaceInvitation.statusStyle
            StatusBadge(text: status == "revoked" ? "Cancelled" : style.label(for: status),
                        systemImage: style.symbol(for: status), tone: style.tone(for: status))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One member

private struct WorkspaceMemberDetailView: View {
    let target: WorkspaceTarget?
    let api: WorkspaceAPI
    let changed: () -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var member: WorkspaceMember
    @State private var feedback: Feedback = .none
    @State private var editingRoles = false
    @State private var confirming: WorkspaceMemberAction?
    @State private var busy = false

    init(member: WorkspaceMember, target: WorkspaceTarget?, api: WorkspaceAPI, changed: @escaping () -> Void) {
        _member = State(initialValue: member)
        self.target = target
        self.api = api
        self.changed = changed
    }

    private var isYou: Bool { target == nil && member.userUUID != nil && member.userUUID == session.user?.uuid }
    private var p: PermissionSet { session.permissions }

    /// How ownership would be handed to this member, if this person may (nil: not offered).
    private var transfer: WorkspaceOwnershipTransfer.Request? {
        WorkspaceOwnershipTransfer.request(isOwner: p.isOwner, isPlatformAdmin: p.isAdmin,
                                           target: target?.uuid, current: session.workspace?.uuid,
                                           memberID: member.id, userUUID: member.userUUID)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(member.name).font(.wsTitle3.bold())
                        if member.isOwner {
                            Image(systemName: "crown.fill").foregroundStyle(Tone.brand.textColor)
                                .accessibilityLabel("Owner")
                        }
                    }
                    let style = WorkspaceMember.statusStyle
                    StatusBadge(text: style.label(for: member.status), systemImage: style.symbol(for: member.status),
                                tone: style.tone(for: member.status))
                }
                .padding(.vertical, 4)
            }
            FeedbackSection(feedback: feedback)
            Section("Details") {
                if let email = member.email { EmailLinkRow(email: email) }
                if let username = member.username { DetailRow(label: "Username", value: username) }
                DetailRow(label: "Roles", value: member.roleSummary)
                if let joined = Formatters.day(member.joinedAt) { DetailRow(label: "Joined", value: joined) }
                if let invitedBy = member.invitedBy { DetailRow(label: "Invited by", value: invitedBy) }
            }
            actions
        }
        .wsDetailList()
        .navigationTitle("Member")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingRoles) {
            MemberRolesSheet(memberID: member.id, currentRoleIDs: member.roleIDs, target: target) {
                feedback = .done("Roles changed. \(member.name) needs to sign in again for them to take effect.")
                changed()
                Task { await reload() }
            }
        }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let action = confirming {
                Button(action.button, role: action.destructive ? .destructive : nil) { Task { await run(action) } }
            }
        } message: {
            Text(confirming?.message(member.name, youAreTheOwner: transfer?.byOwner ?? false) ?? "")
        }
    }

    @ViewBuilder
    private var actions: some View {
        let canUpdate = p.can(.update, moduleName: "users")
        let candidates: [WorkspaceMemberAction?] = [
            canUpdate && !member.isOwner && member.status == "active" ? .editRoles : nil,
            canUpdate && !member.isOwner && member.status == "active" ? .suspend : nil,
            canUpdate && !member.isOwner && member.status == "suspended" ? .activate : nil,
            transfer != nil && !member.isOwner && member.status == "active" ? .transfer : nil,
            p.can(.delete, moduleName: "users") && !member.isOwner && !isYou ? .remove : nil,
        ]
        let rows = candidates.compactMap { $0 }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { action in
                    Button(role: action.destructive ? .destructive : nil) {
                        if action == .editRoles { editingRoles = true } else { confirming = action }
                    } label: {
                        Label(action.button, systemImage: action.symbol)
                    }
                    .frame(minHeight: 44)
                    .disabled(busy)
                    .accessibilityIdentifier("member.action.\(action.rawValue)")
                }
            } footer: {
                if member.isOwner { Text("The owner can’t be changed or removed here. They can hand ownership to someone else.") }
            }
        } else if member.isOwner {
            Section { Text("The owner can’t be changed or removed.").foregroundStyle(.secondaryText) }
        }
    }

    private func run(_ action: WorkspaceMemberAction) async {
        busy = true
        defer { busy = false }
        let path = "/api/v2/namespace/members/\(member.id)"
        switch action {
        case .suspend, .activate:
            let status = action == .suspend ? "suspended" : "active"
            await perform($feedback, done: action == .suspend ? "\(member.name) is suspended and can’t sign in to this workspace."
                                                         : "\(member.name) can use this workspace again.") {
                let root = WorkspaceAPI.object(try await api.send(.put, path, body: .object(["status": .string(status)])))
                if let saved = root.object("member") { member = WorkspaceMember(saved) }
            }
            changed()
        case .transfer:
            guard let request = transfer else { return }
            if await perform($feedback, done: "\(member.name) is now the owner of this workspace.", {
                try await api.send(.post, request.path, body: request.body, namespace: request.byOwner)
            }) {
                changed()
                if target == nil { await session.reloadPermissions() }
                await reload()
            }
        case .remove:
            if await perform($feedback, done: "\(member.name) was removed.", {
                try await api.send(.delete, path)
            }) {
                changed()
                dismiss()
            }
        case .editRoles:
            break
        }
    }

    private func reload() async {
        if let json = try? await api.get("/api/v2/namespace/members/\(member.id)"),
           let record = WorkspaceAPI.record(json, key: "member") {
            member = WorkspaceMember(record)
        }
    }
}

private enum WorkspaceMemberAction: String, Identifiable {
    case editRoles, suspend, activate, transfer, remove
    var id: String { rawValue }

    var button: String {
        switch self {
        case .editRoles: "Change roles"
        case .suspend: "Suspend"
        case .activate: "Let them back in"
        case .transfer: "Make them the owner"
        case .remove: "Remove from this workspace"
        }
    }

    var title: String {
        switch self {
        case .editRoles: "Change roles"
        case .suspend: "Suspend this member?"
        case .activate: "Let this member back in?"
        case .transfer: "Hand over ownership?"
        case .remove: "Remove this member?"
        }
    }

    var symbol: String {
        switch self {
        case .editRoles: "person.badge.key"
        case .suspend: "pause.circle"
        case .activate: "play.circle"
        case .transfer: "crown"
        case .remove: "person.badge.minus"
        }
    }

    var destructive: Bool { self == .suspend || self == .remove || self == .transfer }

    func message(_ name: String, youAreTheOwner: Bool = true) -> String {
        switch self {
        case .editRoles: ""
        case .suspend: "\(name) won’t be able to use this workspace until you let them back in."
        case .activate: "\(name) will be able to use this workspace again with their roles."
        case .transfer:
            youAreTheOwner
                ? "\(name) becomes the owner. You stay a member but are no longer the owner. This can only be undone by the new owner."
                : "\(name) becomes the owner. The current owner stays a member but is no longer the owner."
        case .remove: "\(name) loses access to this workspace straight away. Their account stays."
        }
    }
}

/// Handing a workspace to a member. The workspace's own route (`POST /api/v2/namespace/members/:id/transfer-ownership`)
/// moves ownership away from the caller, so only the real owner can use it (a platform admin who isn't the
/// owner gets a server error there); a platform admin uses the admin route
/// (`POST /api/v2/admin/namespaces/:id/transfer-ownership {new_owner_uuid}`) instead.
enum WorkspaceOwnershipTransfer {
    struct Request: Equatable {
        let path: String
        let body: JSONValue?
        /// The owner's own route (sent with the workspace header); else the admin route.
        let byOwner: Bool
    }

    /// `isOwner` is the signed-in person's ownership of their current workspace; `target` is another
    /// workspace a platform admin is managing.
    static func request(isOwner: Bool, isPlatformAdmin: Bool, target: String?, current: String?,
                        memberID: String, userUUID: String?) -> Request? {
        if isOwner, target == nil {
            return Request(path: "/api/v2/namespace/members/\(memberID)/transfer-ownership", body: nil, byOwner: true)
        }
        guard isPlatformAdmin, let workspace = target ?? current, let userUUID else { return nil }
        return Request(path: "/api/v2/admin/namespaces/\(workspace)/transfer-ownership",
                       body: .object(["new_owner_uuid": .string(userUUID)]), byOwner: false)
    }
}

// MARK: - Roles of a member

/// Chooses a member's roles (`PUT /api/v2/namespace/members/:id {role_ids}`); the owner role isn't offered.
struct MemberRolesSheet: View {
    let memberID: String
    let currentRoleIDs: Set<Int>
    var target: WorkspaceTarget?
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var roles: [Record] = []
    @State private var chosen: Set<Int> = []
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var loaded = false
    @State private var saving = false

    init(memberID: String, currentRoleIDs: Set<Int>, target: WorkspaceTarget? = nil, onSaved: @escaping () -> Void) {
        self.memberID = memberID
        self.currentRoleIDs = currentRoleIDs
        self.target = target
        self.onSaved = onSaved
        _chosen = State(initialValue: currentRoleIDs)
    }

    var body: some View {
        NavigationStack {
            List {
                if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
                FeedbackSection(feedback: feedback)
                Section {
                    ForEach(roles) { role in
                        if let id = role.int("id") {
                            Button {
                                if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(role.string("display_name") ?? Formatters.humanize(role.string("role_name")))
                                            .font(.wsBody)
                                        if let description = role.string("description") {
                                            Text(description).font(.wsFootnote).foregroundStyle(.secondaryText)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: chosen.contains(id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(id) ? Color.accentColor : .secondaryText)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 44)
                            .accessibilityAddTraits(chosen.contains(id) ? .isSelected : [])
                            .accessibilityIdentifier("memberRoles.role.\(id)")
                        }
                    }
                } footer: {
                    Text("They’ll need to sign in again for changes to take effect. With no role they can sign in "
                         + "but can’t open anything.")
                }
            }
            .overlay {
                if !loaded, loadError == nil { SkeletonList() }
                else if loaded, roles.isEmpty, loadError == nil {
                    ContentUnavailableView {
                        Label("No roles to give", systemImage: "person.badge.key")
                    } description: {
                        Text(canMakeRoles ? "This workspace has no roles yet. Make one, then come back to give it."
                             : "This workspace has no roles yet. Ask the person who manages it to add one.")
                    } actions: {
                        if canMakeRoles {
                            NavigationLink { RoleListView() } label: { Text("Make a role") }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("memberRoles.makeRole")
                        }
                    }
                }
            }
            // Back from making a role: show it.
            .onAppear { if loaded { Task { await load() } } }
            .navigationTitle("Change roles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || !loaded || chosen == currentRoleIDs)
                        .accessibilityIdentifier("memberRoles.save")
                }
            }
            .task { await load() }
        }
    }

    /// Roles are made in this workspace only (not in one a platform admin is managing from here).
    private var canMakeRoles: Bool { target == nil && session.permissions.can(.create, moduleName: "roles") }

    private func load() async {
        do {
            let json = try await services.workspace(target).get("/api/v2/namespace/roles")
            roles = WorkspaceAPI.records(json, key: "data").filter { $0.string("role_name")?.lowercased() != "owner" }
            loadError = nil
        } catch {
            loadError = error.asAPIError
        }
        loaded = true
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if await perform($feedback, done: "Roles saved.", {
            try await services.workspace(target).send(.put, "/api/v2/namespace/members/\(memberID)",
                                                      body: MemberRolesSheet.body(chosen))
        }) {
            onSaved()
            dismiss()
        }
    }

    /// `{role_ids: [1, 2]}`; an empty list clears every role.
    static func body(_ ids: Set<Int>) -> JSONValue {
        .object(["role_ids": .array(ids.sorted().map { .number(Double($0)) })])
    }
}

// MARK: - Inviting

/// The workspace's roles to choose from when inviting (the owner role can't be given).
private struct WorkspaceRolePicker: View {
    let api: WorkspaceAPI
    @Binding var chosen: Set<Int>
    var single = false
    @State private var roles: [Record] = []
    @State private var loadError: APIError?

    var body: some View {
        Group {
            if let loadError { InlineErrorRow(error: loadError) { Task { await load() } } }
            if single {
                Picker("Role", selection: Binding(get: { chosen.first ?? -1 },
                                                  set: { chosen = $0 < 0 ? [] : [$0] })) {
                    Text("The default role").tag(-1)
                    ForEach(roles) { role in
                        if let id = role.int("id") { Text(name(role)).tag(id) }
                    }
                }
                .accessibilityIdentifier("invite.role")
            } else {
                ForEach(roles) { role in
                    if let id = role.int("id") {
                        Toggle(name(role), isOn: Binding(get: { chosen.contains(id) }, set: { on in
                            if on { chosen.insert(id) } else { chosen.remove(id) }
                        }))
                        .accessibilityIdentifier("addMember.role.\(id)")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func name(_ role: Record) -> String {
        role.string("display_name") ?? Formatters.humanize(role.string("role_name"))
    }

    private func load() async {
        do {
            roles = WorkspaceAPI.records(try await api.get("/api/v2/namespace/roles"), key: "data")
                .filter { $0.string("role_name")?.lowercased() != "owner" }
            loadError = nil
        } catch {
            loadError = error.asAPIError
        }
    }
}

/// `POST /api/v2/namespace/invitations`: the person gets an email with a link to join.
private struct WorkspaceInviteForm: View {
    let api: WorkspaceAPI
    let sent: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role: Set<Int> = []
    @State private var message = ""
    @State private var days = 7
    @State private var feedback: Feedback = .none
    @State private var sending = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("Their email address", text: $email)
                    .keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("invite.email")
                WorkspaceRolePicker(api: api, chosen: $role, single: true)
                Picker("Link lasts", selection: $days) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text("\($0) day\($0 == 1 ? "" : "s")").tag($0) }
                }
                .accessibilityIdentifier("invite.days")
            } footer: {
                Text("They get an email with a link to join. If they don’t have an account yet, they make one from the link. "
                     + "“The default role” is the role this workspace gives new members, set under Roles and permissions.")
            }
            Section("A note for them (optional)") {
                TextField("e.g. Welcome to the team!", text: $message, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("invite.message")
                if message.count > 500 {
                    Text("Keep it under 500 characters.").font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                }
            }
        }
        .navigationTitle("Invite by email")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { Task { await send() } }
                    .disabled(sending || !WorkspaceInviteForm.looksLikeEmail(email) || message.count > 500)
                    .accessibilityIdentifier("invite.send")
            }
        }
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".") && !trimmed.contains(" ")
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let address = email.trimmingCharacters(in: .whitespaces)
        if await perform($feedback, done: "Sent.", {
            try await api.send(.post, "/api/v2/namespace/invitations",
                               body: WorkspaceInvitation.body(email: address, roleID: role.first, message: message, days: days))
        }) {
            sent(address, days)
            dismiss()
        }
    }
}

/// `POST /api/v2/namespace/members`: adds someone who already has an account, straight away (no email).
private struct WorkspaceAddExistingForm: View {
    let api: WorkspaceAPI
    let added: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var roles: Set<Int> = []
    @State private var feedback: Feedback = .none
    @State private var saving = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("Their email address", text: $email)
                    .keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("addMember.email")
            } footer: {
                Text("They join straight away, without an email. For someone without an account, send an invitation instead.")
            }
            Section("Roles") {
                WorkspaceRolePicker(api: api, chosen: $roles)
            }
        }
        .navigationTitle("Add a member")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await add() } }
                    .disabled(saving || !WorkspaceInviteForm.looksLikeEmail(email))
                    .accessibilityIdentifier("addMember.save")
            }
        }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            var body: [String: JSONValue] = ["email": .string(address)]
            if !roles.isEmpty { body["role_ids"] = .array(roles.sorted().map { .number(Double($0)) }) }
            try await api.send(.post, "/api/v2/namespace/members", body: .object(body))
            added(address)
            dismiss()
        } catch {
            let apiError = error.asAPIError
            if case .notFound = apiError {
                feedback = .failed(ResourceService.problem(422, "Nobody has an account with that email yet. "
                                                           + "Send them an invitation by email instead."))
            } else {
                feedback = .failed(apiError)
            }
        }
    }
}
