import SwiftUI

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @State private var selection: Tab = .myWork
    @State private var showingPendingChanges = false

    enum Tab: Hashable { case myWork, fieldService, more }

    var body: some View {
        let permissions = session.permissions
        TabView(selection: $selection) {
            if showsMyWork(permissions) {
                NavigationStack { MyWorkView().withAppDestinations() }
                    .tabItem { Label("My Work", systemImage: "person.badge.clock") }
                    .tag(Tab.myWork)
            }
            if showsFieldService(permissions) {
                NavigationStack { FieldServiceHubView().withAppDestinations() }
                    .tabItem { Label("Field Service", systemImage: "wrench.and.screwdriver") }
                    .tag(Tab.fieldService)
            }
            NavigationStack { MoreView().withAppDestinations() }
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(Tab.more)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Button {
                showingPendingChanges = true
            } label: {
                SyncStatusBanner(isOnline: connectivity.isOnline, pendingCount: sync.pendingCount,
                                 failedCount: sync.failedCount)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sync.banner")
        }
        .sheet(isPresented: $showingPendingChanges) {
            NavigationStack { PendingChangesView() }
        }
        .onAppear { selection = initialTab(permissions) }
    }

    private func showsMyWork(_ permissions: PermissionSet) -> Bool {
        NavigationPolicy(permissions: permissions, isEngineerRole: session.policy.isEngineerRole).showsMyWork
    }

    private func showsFieldService(_ permissions: PermissionSet) -> Bool {
        NavigationPolicy(permissions: permissions, isEngineerRole: session.policy.isEngineerRole).showsFieldService
    }

    private func initialTab(_ permissions: PermissionSet) -> Tab {
        switch NavigationPolicy(session: session).home {
        case .myWork: .myWork
        case .fieldService: .fieldService
        case .more: .more
        }
    }
}

struct MoreView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @State private var confirmingSignOut = false

    var body: some View {
        List {
            if let user = session.user {
                Section {
                    HStack(spacing: 14) {
                        Text(user.initials)
                            .font(.headline)
                            .frame(width: 48, height: 48)
                            .background(Color.accentColor.opacity(0.15), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(user.displayName).font(.headline)
                            Text(user.email).font(.subheadline).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    NavigationLink {
                        WorkspacePickerView(isInitialChoice: false)
                    } label: {
                        LabeledContent {
                            Text(session.workspace?.name ?? "None")
                        } label: {
                            Label("Workspace", systemImage: "building.2")
                        }
                    }
                    .accessibilityIdentifier("more.workspace")
                }
            }

            Section("Modules") {
                moduleLinks
            }

            Section {
                NavigationLink {
                    PendingChangesView()
                } label: {
                    LabeledContent {
                        Text(sync.mutations.isEmpty ? "All synced" : "\(sync.mutations.count)")
                    } label: {
                        Label("Unsynced changes", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            Section {
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("more.signOut")
            }
        }
        .navigationTitle("More")
        .confirmationDialog(signOutTitle, isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await session.signOut() }
            }
        } message: {
            if hasUnsynced {
                Text("You have \(sync.mutations.count) change(s) that haven't reached the server. They stay on this device and sync the next time you sign in.")
            }
        }
    }

    private var hasUnsynced: Bool {
        guard let user = session.user else { return false }
        return sync.hasUnsyncedWrites(forUser: user.uuid)
    }

    private var signOutTitle: String {
        hasUnsynced ? "Sign out with unsynced changes?" : "Sign out of \(Brand.current.name)?"
    }

    @ViewBuilder
    private var moduleLinks: some View {
        let permissions = session.permissions
        if permissions.shows(.crm) {
            NavigationLink { CRMHomeView() } label: { Label("CRM", systemImage: "person.2.crop.square.stack") }
        }
        if permissions.shows(.customers) {
            NavigationLink { CustomersListView() } label: { Label("Customers", systemImage: "person.crop.rectangle.stack") }
        }
        if permissions.shows(.products) {
            NavigationLink { ProductsListView() } label: { Label("Products", systemImage: "shippingbox") }
        }
        if permissions.shows(.orders) {
            NavigationLink { OrdersListView() } label: { Label("Orders", systemImage: "cart") }
        }
        if permissions.shows(.invoices) {
            NavigationLink { InvoicesListView() } label: { Label("Invoices", systemImage: "doc.text") }
        }
        // Value links: these screens push further value routes (asset, report), and a destination
        // link above them makes SwiftUI rebuild the list, dropping its filters and the row tap.
        if permissions.can(.read, .fsAssets) {
            NavigationLink(value: FieldServiceArea.customerAssets) {
                Label("Assets", systemImage: "air.conditioner.horizontal")
            }
            .accessibilityIdentifier("more.customerAssets")
        }
        if permissions.can(.read, .fsReports) {
            NavigationLink(value: FieldServiceArea.reports) {
                Label("Reports", systemImage: "chart.bar.doc.horizontal")
            }
            .accessibilityIdentifier("more.reports")
        }
    }
}
