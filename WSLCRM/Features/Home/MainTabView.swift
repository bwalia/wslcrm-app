import SwiftUI

/// The signed-in app: three kinds of tab, always in the same places.
///
/// - **Home** — the dashboard: greeting, your work, today's numbers, quick actions, your apps.
/// - **Shortcuts** — up to three the person pinned (Settings › Tab bar, or press and hold an app),
///   or, until they pin any, their busiest work areas.
/// - **Apps** — everything else in the workspace, every entry a native screen.
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
    @State private var appPaths: [String: NavigationPath] = [:]

    var body: some View {
        let policy = NavigationPolicy(session: session)
        let slots = TabBarLayout.slots(policy: policy, catalog: AppCatalog(menu: session.menu),
                                       pins: HomePreferences.shared.pins)
        TabView(selection: $selection) {
            NavigationStack(path: $homePath) {
                HomeView(hubs: policy.ordered, open: { open($0, slots: slots) })
                    .withAppDestinations()
                    .navigationDestination(for: HubScreenRoute.self) { $0.hub.rootView }
                    .navigationDestination(for: ChatLinkTarget.self) { ChatLinkDestinationView(target: $0) }
                    .safeAreaInset(edge: .top, spacing: 0) { syncBanner }
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(AppTab.home)
            // Only for what needs the person: changes the server refused.
            .badge(sync.failedCount)

            // Up to three in between: the person's pins, or their busiest work areas.
            ForEach(slots) { slot in
                tabContent(slot)
                    .tabItem { Label(slot.title, systemImage: slot.systemImage) }
                    .tag(slot.tab)
            }

            NavigationStack {
                AppsView()
                    .withAppDestinations()
                    .safeAreaInset(edge: .top, spacing: 0) { syncBanner }
            }
            .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            .tag(AppTab.apps)
        }
        .sheet(isPresented: $showingPendingChanges) {
            NavigationStack { PendingChangesView() }
        }
        .onAppear {
            activatePreferences()
            openLandingPage()
            openPendingLink()
            openPendingNotification()
        }
        .onChange(of: session.workspace?.uuid) { activatePreferences() }
        .onChange(of: router.pending) { openPendingLink() }
        // A shortcut that was unpinned while open: back to Home rather than an empty selection.
        .onChange(of: slots.map(\.tab)) { _, tabs in
            if case .home = selection { return }
            if case .apps = selection { return }
            if !tabs.contains(selection) { selection = .home }
        }
    }

    @ViewBuilder
    private func tabContent(_ slot: TabSlot) -> some View {
        switch slot.pin {
        case .hub(let hub):
            NavigationStack(path: hubPath(hub)) {
                hub.rootView
                    .withAppDestinations()
                    .safeAreaInset(edge: .top, spacing: 0) { syncBanner }
            }
        case .app(let key):
            NavigationStack(path: appPath(key)) {
                Group {
                    if let destination = NativeModules.destination(forKey: key) { destination.rootView }
                }
                .withAppDestinations()
                .safeAreaInset(edge: .top, spacing: 0) { syncBanner }
            }
        }
    }

    /// Opens a work area from Home: its tab when it has one, else on Home's own stack.
    private func open(_ tab: AppTab, slots: [TabSlot]) {
        if slots.contains(where: { $0.tab == tab }) || tab == .apps || tab == .home {
            selection = tab
        } else if case .hub(let hub) = tab {
            homePath.append(HubScreenRoute(hub: hub))
        }
    }

    private func appPath(_ key: String) -> Binding<NavigationPath> {
        Binding(get: { appPaths[key] ?? NavigationPath() }, set: { appPaths[key] = $0 })
    }

    /// This person's work-area order for this workspace (Edit Home, and what was waiting last time).
    private func activatePreferences() {
        guard let user = session.user?.uuid, let workspace = session.workspace?.uuid else { return }
        HomePreferences.shared.activate(user: user, workspace: workspace)
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
            // A chat message: the conversation, on Home (chat has no hub of its own).
            if case .chat(let channel) = link.target {
                guard NativeModules.destination(forKey: AppMenu.aiChatKey) != nil,
                      session.permissions.menuKeys.contains(AppMenu.aiChatKey) else { return }
                selection = .home
                var path = NavigationPath()
                path.append(NativeScreenRoute(ChatScreens.conversation(channel)))
                homePath = path
                return
            }
            let policy = NavigationPolicy(session: session)
            let hub: NavigationPolicy.Home = link.target.isPA ? .propertyPA : .propertyDeals
            guard hub == .propertyPA ? policy.showsPropertyPA : policy.showsPropertyDeals else { return }
            let slots = TabBarLayout.slots(policy: policy, catalog: AppCatalog(menu: session.menu),
                                           pins: HomePreferences.shared.pins)
            if slots.contains(where: { $0.pin == .hub(hub) }) {
                selection = .hub(hub)
                hubPaths[hub] = Self.path(for: link.target, startingAtHub: nil)
            } else {
                // No tab for it: open the hub's screen on Home, then the item.
                selection = .home
                homePath = Self.path(for: link.target, startingAtHub: hub)
            }
        }
    }

    /// Just signed in: the role's landing page (Roles › Opens after sign-in) opens first, on Home.
    /// The web's home page (`/dashboard`) is Home itself.
    private func openLandingPage() {
        guard let path = session.landingPath else { return }
        session.landingPath = nil
        guard let item = ChatLinks.menuItem(for: path, in: session.menu), !AppCatalog.hiddenKeys.contains(item.key),
              let destination = MenuDestination.of(item) else { return }
        selection = .home
        var stack = NavigationPath()
        stack.append(ChatLinkTarget.menu(destination, title: item.name))
        homePath = stack
    }

    /// A notification opened from another workspace: the switch rebuilt this view; open its record on Home.
    private func openPendingNotification() {
        guard let path = PendingNotificationPage.take(), let url = URL(string: path),
              case .native(let target) = ChatLinks.resolve(url, dashboardHost: nil, menu: session.menu) else { return }
        selection = .home
        var stack = NavigationPath()
        stack.append(target)
        homePath = stack
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
        case .today, .paCard, .paBrief, .chat: break
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
