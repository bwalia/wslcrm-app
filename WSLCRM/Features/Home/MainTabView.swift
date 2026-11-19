import SwiftUI

/// The signed-in app: three kinds of tab, always in the same places.
///
/// - **Home** — the dashboard: greeting, your work, today's numbers, quick actions, your apps.
/// - **Work hubs** — up to three, the person's own first (PA, My Work, Field Service, Deals, …).
/// - **Apps** — everything else in the workspace, native screens first, web pages marked "Web".
///
/// The profile, workspace switch, sync queue, settings and sign out live behind the avatar on
/// Home, as in Apple's own apps.
struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(DeepLinkRouter.self) private var router
    @State private var selection: AppTab = .home
    @State private var showingPendingChanges = false
    @State private var homePath = NavigationPath()
    @State private var hubPaths: [NavigationPolicy.Home: NavigationPath] = [:]
    @State private var assistant: WebPageRoute?

    var body: some View {
        let hubs = NavigationPolicy(session: session).tabs
        TabView(selection: $selection) {
            NavigationStack(path: $homePath) {
                HomeView(hubs: hubs, open: { selection = $0 }, assistant: $assistant)
                    .withAppDestinations()
                    .safeAreaInset(edge: .top, spacing: 0) { syncBanner }
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(AppTab.home)
            // Only for what needs the person: changes the server refused.
            .badge(sync.failedCount)

            ForEach(hubs, id: \.self) { hub in
                NavigationStack(path: hubPath(hub)) {
                    hub.rootView
                        .withAppDestinations()
                        .safeAreaInset(edge: .top, spacing: 0) { syncBanner }
                }
                .tabItem { Label(hub.title, systemImage: hub.systemImage) }
                .tag(AppTab.hub(hub))
            }

            NavigationStack {
                AppsView(assistant: $assistant)
                    .withAppDestinations()
                    .safeAreaInset(edge: .top, spacing: 0) { syncBanner }
            }
            .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            .tag(AppTab.apps)
        }
        .sheet(isPresented: $showingPendingChanges) {
            NavigationStack { PendingChangesView() }
        }
        .sheet(item: $assistant) { AssistantSheet(route: $0) }
        .onAppear { openPendingLink() }
        .onChange(of: router.pending) { openPendingLink() }
    }

    private func hubPath(_ hub: NavigationPolicy.Home) -> Binding<NavigationPath> {
        Binding(get: { hubPaths[hub] ?? NavigationPath() }, set: { hubPaths[hub] = $0 })
    }

    /// Opens a push tap or `wslcrm://` link, switching workspace first when it belongs to another
    /// one. A switch rebuilds this view (`workspaceGeneration`), and the new one opens the link.
    /// The link opens on its hub's tab; where that hub has no tab, on Home.
    private func openPendingLink() {
        guard let link = router.pending else { return }
        switch DeepLinkResolver.resolve(link, currentWorkspaceId: session.workspace?.uuid, workspaces: session.workspaces) {
        case .switchWorkspace(let workspace):
            Task { await session.select(workspace) }
        case .ignore:
            router.clear()
        case .open:
            router.clear()
            let policy = NavigationPolicy(session: session)
            let hub: NavigationPolicy.Home = link.target.isPA ? .propertyPA : .propertyDeals
            guard hub == .propertyPA ? policy.showsPropertyPA : policy.showsPropertyDeals else { return }
            if policy.tabs.contains(hub) {
                selection = .hub(hub)
                hubPaths[hub] = Self.path(for: link.target, startingAtHub: nil)
            } else {
                // No tab for it: open the hub's screen on Home, then the item.
                selection = .home
                homePath = Self.path(for: link.target, startingAtHub: hub)
            }
        }
    }

    /// The navigation for a link: optionally the hub's own screen first, then the item.
    private static func path(for target: AppDeepLink.Target, startingAtHub hub: NavigationPolicy.Home?) -> NavigationPath {
        var path = NavigationPath()
        switch hub {
        case .propertyPA: path.append(PATodayRoute(manager: false))
        case .propertyDeals: path.append(NativeScreen.propertyDealsToday)
        default: break
        }
        switch target {
        case .handoff(let uuid): path.append(PAHandoffRoute(uuid: uuid))
        case .paCapture(let uuid): path.append(PACaptureRoute(uuid: uuid))
        case .task(let uuid): path.append(PDTaskRoute(uuid: uuid))
        case .approval(let uuid): path.append(PDApprovalRoute(uuid: uuid))
        case .deal(let uuid): path.append(PDDealRoute(uuid: uuid))
        case .today, .paCard, .paBrief: break
        }
        return path
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
}
