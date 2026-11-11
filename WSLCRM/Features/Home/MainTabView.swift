import SwiftUI

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(DeepLinkRouter.self) private var router
    @State private var selection: Tab = .myWork
    @State private var showingPendingChanges = false
    @State private var propertyDealsPath = NavigationPath()
    @State private var propertyPAPath = NavigationPath()

    enum Tab: Hashable { case propertyPA, myWork, fieldService, propertyDeals, leads, tasks, shop, more }

    var body: some View {
        let navigation = NavigationPolicy(session: session)
        let tabs = navigation.tabs
        TabView(selection: $selection) {
            if tabs.contains(.propertyPA) {
                NavigationStack(path: $propertyPAPath) { PATodayView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("PA", systemImage: "sparkles") }
                    .tag(Tab.propertyPA)
            }
            if tabs.contains(.myWork) {
                NavigationStack { MyWorkView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("My Work", systemImage: "person.badge.clock") }
                    .tag(Tab.myWork)
            }
            if tabs.contains(.fieldService) {
                NavigationStack { FieldServiceHubView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("Field Service", systemImage: "wrench.and.screwdriver") }
                    .tag(Tab.fieldService)
            }
            if tabs.contains(.propertyDeals) {
                NavigationStack(path: $propertyDealsPath) { PDTodayView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("Deals", systemImage: "house.and.flag") }
                    .tag(Tab.propertyDeals)
            }
            if tabs.contains(.leads) {
                NavigationStack { LeadsHomeView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("Leads", systemImage: "person.crop.circle.badge.plus") }
                    .tag(Tab.leads)
            }
            if tabs.contains(.tasks) {
                NavigationStack { MyTasksView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("Tasks", systemImage: "checklist") }
                    .tag(Tab.tasks)
            }
            if tabs.contains(.shop) {
                NavigationStack { ShopHomeView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                    .tabItem { Label("Shop", systemImage: "storefront") }
                    .tag(Tab.shop)
            }
            NavigationStack { MenuView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                .tabItem { Label("Menu", systemImage: "line.3.horizontal") }
                .tag(Tab.more)
        }
        .sheet(isPresented: $showingPendingChanges) {
            NavigationStack { PendingChangesView() }
        }
        .onAppear {
            selection = initialTab()
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
            if link.target.isPA {
                guard NavigationPolicy(session: session).tabs.contains(.propertyPA) else { return }
                selection = .propertyPA
                var path = NavigationPath()
                switch link.target {
                case .handoff(let uuid): path.append(PAHandoffRoute(uuid: uuid))
                case .paCapture(let uuid): path.append(PACaptureRoute(uuid: uuid))
                default: break
                }
                propertyPAPath = path
                return
            }
            guard NavigationPolicy(session: session).tabs.contains(.propertyDeals) else { return }
            selection = .propertyDeals
            var path = NavigationPath()
            switch link.target {
            case .task(let uuid): path.append(PDTaskRoute(uuid: uuid))
            case .approval(let uuid): path.append(PDApprovalRoute(uuid: uuid))
            case .deal(let uuid): path.append(PDDealRoute(uuid: uuid))
            case .today: break
            case .paCard, .paBrief, .handoff, .paCapture: break
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

    private func initialTab() -> Tab {
        let navigation = NavigationPolicy(session: session)
        let home = navigation.home
        // A home that didn't get a tab (shouldn't happen: `tabs` keeps it) falls back to Menu.
        guard home == .more || navigation.tabs.contains(home) else { return .more }
        return switch home {
        case .propertyPA: .propertyPA
        case .myWork: .myWork
        case .fieldService: .fieldService
        case .propertyDeals: .propertyDeals
        case .leads: .leads
        case .tasks: .tasks
        case .shop: .shop
        case .more: .more
        }
    }
}
