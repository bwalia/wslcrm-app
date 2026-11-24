import SwiftUI

/// Lists the user's namespaces. Selecting one re-scopes every request and re-fetches all data.
/// Also where invitations are answered, and (when this service allows it) a workspace is made.
struct WorkspacePickerView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    let isInitialChoice: Bool
    @State private var switchingTo: String?
    @State private var inbox = InvitationInbox()
    @State private var directory = WorkspaceDirectory()
    @State private var creating = false
    @State private var search = ""
    @State private var feedback: Feedback = .none
    @State private var isDeliveryPartner = false
    @State private var confirmingSignOut = false

    var body: some View {
        List {
            // A delivery partner's drops need no workspace: reachable before one is chosen (or without any).
            if isInitialChoice, isDeliveryPartner {
                Section {
                    NavigationLink {
                        NativeScreenView(route: NativeScreenRoute(SalesScreen.myDeliveries))
                    } label: {
                        MyDeliveries.entryLabel.font(.wsHeadline).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("workspace.myDeliveries")
                } footer: {
                    Text("The orders you're delivering, and signing for them on delivery.")
                }
            }
            if session.workspaces.isEmpty {
                noWorkspaceSection
            }
            FeedbackSection(feedback: inbox.feedback)
            FeedbackSection(feedback: feedback)
            if !inbox.items.isEmpty {
                Section("Invitations") {
                    ForEach(inbox.items) { InvitationCard(invitation: $0, inbox: inbox) }
                }
            }
            if !session.workspaces.isEmpty {
                Section {
                    ForEach(shown) { workspace in
                        row(workspace)
                    }
                    if shown.isEmpty {
                        Text("No workspace is called “\(search)”.").foregroundStyle(.secondaryText)
                    }
                } footer: {
                    Text("Switching workspace reloads jobs, visits and other data for that workspace. Swipe right "
                         + "on one to make it your default: it opens first when you sign in.")
                }
            }
            if directory.canCreate {
                Section {
                    Button { creating = true } label: {
                        Label("Create a workspace", systemImage: "plus.circle")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("workspace.create")
                } footer: {
                    Text("Start a new workspace for your own company. You'll be its owner.")
                }
            }
        }
        .navigationTitle(isInitialChoice ? "Choose a workspace" : "Workspace")
        .toolbar {
            if isInitialChoice {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { confirmingSignOut = true }
                        .accessibilityIdentifier("workspace.signOut")
                }
            }
        }
        .searchable(text: $search, prompt: "Find a workspace")
        .task { await load() }
        .refreshable {
            await session.reloadWorkspaces()
            await load()
        }
        .sheet(isPresented: $creating) { CreateWorkspaceSheet() }
        .confirmationDialog("Sign out of \(BrandStore.shared.brand.name)?", isPresented: $confirmingSignOut,
                            titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await session.signOut() } }
        } message: {
            Text("You'll need your email and password to sign in again.")
        }
    }

    /// Nobody has added this person to a workspace: say why, and how to get in.
    private var noWorkspaceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("You're not in a workspace yet", systemImage: "building.2")
                    .font(.wsHeadline)
                Text(noWorkspaceAdvice)
                    .font(.wsSubheadline)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("workspace.none")
            if let error = session.permissionsError, error.isConnectivityProblem {
                InlineErrorRow(error: error) { Task { await session.reloadWorkspaces() } }
            }
        }
    }

    private var noWorkspaceAdvice: String {
        let email = session.user?.email.trimmedOrNil.map { " (\($0))" } ?? ""
        var text = "A workspace is where your company's customers, work and people are kept. Ask the person who "
            + "manages yours to invite this account\(email). Their invitation appears here; pull down to check again."
        if directory.canCreate { text += " Or create a workspace of your own below." }
        return text
    }

    private func row(_ workspace: Workspace) -> some View {
        Button {
            choose(workspace)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "building.2.fill")
                    .font(.wsTitle3)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name).font(.wsHeadline).foregroundStyle(.primary)
                    let notes = [workspace.isOwner ? "Owner" : nil,
                                 directory.defaultUuid == workspace.uuid ? "Your default" : nil].compactMap { $0 }
                    if !notes.isEmpty {
                        Text(notes.joined(separator: " · ")).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                }
                Spacer()
                if switchingTo == workspace.uuid {
                    ProgressView()
                } else if session.workspace?.uuid == workspace.uuid {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.wsTitle3)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
            .frame(minHeight: 56)
        }
        .disabled(switchingTo != nil)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if directory.defaultUuid != workspace.uuid {
                Button("Make default") { Task { await makeDefault(workspace) } }
                    .tint(.accentColor)
            }
        }
        .accessibilityIdentifier("workspace.\(workspace.slug ?? workspace.uuid)")
    }

    private var shown: [Workspace] {
        guard let query = search.trimmedOrNil else { return session.workspaces }
        return session.workspaces.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func makeDefault(_ workspace: Workspace) async {
        if await perform($feedback, done: "\(workspace.name) is now your default workspace.", {
            try await services.workspace().makeDefault(workspace.uuid)
        }) {
            directory.defaultUuid = workspace.uuid
        }
    }

    private func load() async {
        let api = services.workspace()
        await inbox.load(api)
        if let found = try? await api.directory() { directory = found }
        if isInitialChoice { isDeliveryPartner = await MyDeliveries.isPartner(services) }
    }

    private func choose(_ workspace: Workspace) {
        guard session.workspace?.uuid != workspace.uuid else {
            if !isInitialChoice { dismiss() }
            return
        }
        switchingTo = workspace.uuid
        Task {
            await session.select(workspace)
            switchingTo = nil
        }
    }
}
