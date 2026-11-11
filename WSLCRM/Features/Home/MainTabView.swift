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

    typealias Tab = NavigationPolicy.Home

    var body: some View {
        let tabs = NavigationPolicy(session: session).tabs
        TabView(selection: $selection) {
            // In `tabs` order: the person's home first, then AI and Projects, then the rest.
            ForEach(tabs, id: \.self) { tab in
                content(for: tab)
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

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        switch tab {
        case .propertyPA:
            NavigationStack(path: $propertyPAPath) { PATodayView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                .tabItem { Label("PA", systemImage: "sparkles") }
                .tag(tab)
        case .myWork:
            NavigationStack { MyWorkView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                .tabItem { Label("My Work", systemImage: "person.badge.clock") }
                .tag(tab)
        case .fieldService:
            NavigationStack { FieldServiceHubView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                .tabItem { Label("Field Service", systemImage: "wrench.and.screwdriver") }
                .tag(tab)
        case .propertyDeals:
            NavigationStack(path: $propertyDealsPath) { PDTodayView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                .tabItem { Label("Deals", systemImage: "house.and.flag") }
                .tag(tab)
        case .leads:
            NavigationStack { LeadsHomeView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                .tabItem { Label("Leads", systemImage: "person.crop.circle.badge.plus") }
                .tag(tab)
        case .tasks:
            NavigationStack { MyTasksView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(tab)
        case .shop:
            NavigationStack { ShopHomeView().withAppDestinations().safeAreaInset(edge: .top, spacing: 0) { syncBanner } }
                .tabItem { Label("Shop", systemImage: "storefront") }
                .tag(tab)
        // The AI chat and project management are the web's own pages, so they work exactly as there.
        case .ai:
            NavigationStack { webTab(AppMenu.aiChatKey, fallback: "AI Navigator").withAppDestinations() }
                .tabItem { Label("AI", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(tab)
        case .projects:
            NavigationStack { webTab(AppMenu.projectsKey, fallback: "Projects").withAppDestinations() }
                .tabItem { Label("Projects", systemImage: "rectangle.split.3x1") }
                .tag(tab)
        case .more:
            EmptyView()
        }
    }

    /// A tab that is a web dashboard page: the menu item's own name and address.
    @ViewBuilder
    private func webTab(_ key: String, fallback: String) -> some View {
        if let route = session.menu.route(for: key) {
            WebPageView(route: route)
        } else {
            ContentUnavailableView(fallback, systemImage: "exclamationmark.triangle",
                                   description: Text("This isn't in your menu for this workspace."))
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
        // A home that didn't get a tab (shouldn't happen: `tabs` keeps it) falls back to Menu.
        return navigation.tabs.contains(navigation.home) ? navigation.home : .more
    }
}
