import SwiftUI

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(DeepLinkRouter.self) private var router
    @State private var selection: Tab = .myWork
    @State private var showingPendingChanges = false
    @State private var propertyDealsPath = NavigationPath()

    enum Tab: Hashable { case myWork, fieldService, propertyDeals, tasks, shop, more }

    var body: some View {
        let permissions = session.permissions
        TabView(selection: $selection) {
            if showsMyWork(permissions) {
                NavigationStack { MyWorkView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("My Work", systemImage: "person.badge.clock") }
                    .tag(Tab.myWork)
            }
            if showsFieldService(permissions) {
                NavigationStack { FieldServiceHubView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("Field Service", systemImage: "wrench.and.screwdriver") }
                    .tag(Tab.fieldService)
            }
            if NavigationPolicy(session: session).showsPropertyDeals {
                NavigationStack(path: $propertyDealsPath) { PDTodayView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("Deals", systemImage: "house.and.flag") }
                    .tag(Tab.propertyDeals)
            }
            if NavigationPolicy(session: session).showsTasks {
                NavigationStack { MyTasksView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("Tasks", systemImage: "checklist") }
                    .tag(Tab.tasks)
            }
            if NavigationPolicy(session: session).showsShop {
                NavigationStack { ShopHomeView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("Shop", systemImage: "storefront") }
                    .tag(Tab.shop)
            }
            NavigationStack { MoreView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(Tab.more)
        }
        .sheet(isPresented: $showingPendingChanges) {
            NavigationStack { PendingChangesView() }
        }
        .onAppear {
            selection = initialTab(permissions)
            openPendingLink()
        }
        .onChange(of: router.pending) { openPendingLink() }
    }

    /// Opens a push tap or `wslcrm://` link, switching workspace first when it belongs to another
    /// one. A switch rebuilds this view (`workspaceGeneration`), and the new one opens the link.
    private func openPendingLink() {
        guard let link = router.pending else { return }
        switch DeepLinkResolver.resolve(link, currentWorkspaceId: session.workspace?.uuid, workspaces: session.workspaces) {
        case .switchWorkspace(let workspace):
            Task { await session.select(workspace) }
        case .ignore:
            router.clear()
        case .open:
            router.clear()
            guard NavigationPolicy(session: session).showsPropertyDeals else { return }
            selection = .propertyDeals
            var path = NavigationPath()
            switch link.target {
            case .task(let uuid): path.append(PDTaskRoute(uuid: uuid))
            case .approval(let uuid): path.append(PDApprovalRoute(uuid: uuid))
            case .deal(let uuid): path.append(PDDealRoute(uuid: uuid))
            case .today: break
            }
            propertyDealsPath = path
        }
    }

    /// Offline / unsynced state, just under each tab's navigation bar. (Inset on the TabView or the
    /// NavigationStack, iOS 26 draws it over the bar and its buttons.)
    private var syncBanner: some View {
        Button {
            showingPendingChanges = true
        } label: {
            SyncStatusBanner(isOnline: connectivity.isOnline, pendingCount: sync.pendingCount,
                             failedCount: sync.failedCount)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sync.banner")
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
        case .propertyDeals: .propertyDeals
        case .tasks: .tasks
        case .shop: .shop
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
                .accessibilityIdentifier("more.pendingChanges")
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("more.settings")
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
                .accessibilityIdentifier("more.crm")
        }
        if permissions.shows(.customers) {
            NavigationLink { CustomersListView() } label: { Label("Customers", systemImage: "person.crop.rectangle.stack") }
                .accessibilityIdentifier("more.customers")
        }
        if permissions.shows(.products) {
            NavigationLink { ProductsListView() } label: { Label("Products", systemImage: "shippingbox") }
                .accessibilityIdentifier("more.products")
        }
        if permissions.shows(.orders) {
            NavigationLink { OrdersListView() } label: { Label("Orders", systemImage: "cart") }
                .accessibilityIdentifier("more.orders")
        }
        if permissions.shows(.invoices) {
            NavigationLink { InvoicesListView() } label: { Label("Invoices", systemImage: "doc.text") }
                .accessibilityIdentifier("more.invoices")
        }
        if permissions.shows(.purchaseOrders) {
            NavigationLink(value: PurchaseOrdersRoute()) { Label("Purchase orders", systemImage: "shippingbox.and.arrow.backward") }
                .accessibilityIdentifier("more.purchaseOrders")
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
        // Work management. Projects are membership- and grant-gated; logging your own time is
        // not, so timesheets are offered to everyone signed in. My tasks has its own tab.
        if permissions.shows(.projects) || permissions.can(.read, .projects) {
            NavigationLink(value: FieldServiceArea.projects) {
                Label("Projects", systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("more.projects")
            NavigationLink(value: FieldServiceArea.reviewQueue) {
                Label("Waiting for me", systemImage: "person.crop.circle.badge.questionmark")
            }
            .accessibilityIdentifier("more.reviewQueue")
        }
        NavigationLink(value: FieldServiceArea.timesheets) {
            Label("Timesheets", systemImage: "clock.badge.checkmark")
        }
        .accessibilityIdentifier("more.timesheets")
    }
}
