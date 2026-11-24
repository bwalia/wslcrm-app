import SwiftUI

/// Home: the first thing someone sees after signing in. A greeting, their work, today's numbers,
/// one-tap actions and their apps — a dashboard to start from and come back to, whatever the role.
struct HomeView: View {
    let hubs: [NavigationPolicy.Home]
    let open: (AppTab) -> Void

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var digest = HomeDigest()
    @State private var editingHome = false
    @State private var showingProfile = false
    @State private var showingCapture = false
    @State private var creatingRequest = false
    @State private var createdRequest: ServiceRequestRoute?
    @State private var toast: String?
    @State private var invitations = InvitationInbox()
    @State private var notifications = NotificationsModel()
    @State private var showingNotifications = false
    @State private var isDeliveryPartner = false

    var body: some View {
        let catalog = AppCatalog(menu: session.menu)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HomeHero(showingProfile: $showingProfile, showingNotifications: $showingNotifications,
                         unread: notifications.unread)

                if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.brandCallout)
                        .foregroundStyle(Tone.success.textColor)
                        .brandCard(padding: 12, radius: 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if MenuLoadFailedCard.applies(hasWorkspace: session.workspace != nil, error: session.permissionsError,
                                              menuIsEmpty: session.menu.isEmpty) {
                    MenuLoadFailedCard()
                }
                if !invitations.items.isEmpty || !invitations.feedback.isNone { invitationsSection }
                // Delivery partners (no workspace needed): their drops, signed for on delivery.
                if isDeliveryPartner {
                    NavigationLink(value: NativeScreenRoute(SalesScreen.myDeliveries)) {
                        HStack {
                            MyDeliveries.entryLabel.font(.brandHeadline)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondaryText)
                        }
                        .brandCard(padding: 16, radius: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.myDeliveries")
                }
                if !HomeDigest.sources(session: session).isEmpty { todaySection }
                if !hubs.isEmpty { workSection }
                quickActions(catalog: catalog)
                if !catalog.nativeEntries.isEmpty { appsSection(catalog: catalog) }
                if NoAccessCard.applies(hasWorkspace: session.workspace != nil, menuFailed: session.permissionsError != nil,
                                        hasApps: !catalog.groups.isEmpty, hasWork: !hubs.isEmpty,
                                        isDeliveryPartner: isDeliveryPartner) {
                    NoAccessCard()
                }
                // The AI Navigator, once its native screen is in this person's menu.
                if let chat = catalog.entry(forKey: AppMenu.aiChatKey) {
                    AppEntryLink(entry: chat) { AssistantCardLabel() }
                        .accessibilityIdentifier("home.assistant")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .brandCanvas()
        // A running task timer, wherever it was started (hidden when none is running).
        .workRunningTimer()
        .overlay(alignment: .top) { StatusBarBackdrop() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Home")
        .wsRefreshable {
            await session.reloadPermissions()
            await digest.load(session: session, services: services)
            await invitations.load(services.workspace())
            await notifications.load(services.workspace())
        }
        .task(id: session.workspace?.uuid) {
            await digest.load(session: session, services: services)
            await invitations.load(services.workspace())
            await notifications.load(services.workspace())
            isDeliveryPartner = await MyDeliveries.isPartner(services)
        }
        .sheet(isPresented: $showingNotifications) { NotificationsView(model: notifications) }
        .onAppear {
            // Said once after joining or making a workspace (the switch rebuilt Home).
            if let notice = session.notice {
                toast = notice
                session.notice = nil
            }
        }
        .sheet(isPresented: $editingHome) {
            let policy = NavigationPolicy(session: session)
            EditHomeSheet(available: policy.available, current: policy.ordered)
        }
        .sheet(isPresented: $showingProfile) { ProfileSheet() }
        .sheet(isPresented: $showingCapture) {
            PDQuickCaptureView { message in withAnimation { toast = message } }
        }
        .sheet(isPresented: $creatingRequest) {
            ServiceRequestFormSheet(request: nil) { created in
                createdRequest = ServiceRequestRoute(uuid: created.request.uuid)
            }
        }
        .navigationDestination(item: $createdRequest) { ServiceRequestDetailView(requestUuid: $0.uuid) }
        .accessibilityIdentifier("home.dashboard")
    }

    // MARK: Invitations

    /// Workspaces that have invited this person: join or decline here.
    private var invitationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Invitations")
            FeedbackRow(feedback: invitations.feedback)
            ForEach(invitations.items) { invitation in
                InvitationCard(invitation: invitation, inbox: invitations)
                    .brandCard(padding: 14, radius: 18)
            }
        }
        .accessibilityIdentifier("home.invitations")
    }

    // MARK: Your work

    private var workSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Your work") {
                Button("Edit") { editingHome = true }
                    .accessibilityIdentifier("home.editWork")
            }
            if let first = hubs.first {
                Button { open(.hub(first)) } label: { PrimaryHubCard(hub: first) }
                    .buttonStyle(.pressableCard)
                    .accessibilityIdentifier("home.hub.\(first.title)")
            }
            let others = Array(hubs.dropFirst())
            if !others.isEmpty {
                LazyVGrid(columns: others.count == 1 ? [GridItem(.flexible())] : columns(min: 150), spacing: 10) {
                    ForEach(others, id: \.self) { hub in
                        Button { open(.hub(hub)) } label: { HubCard(hub: hub) }
                            .buttonStyle(.pressableCard)
                            .accessibilityIdentifier("home.hub.\(hub.title)")
                    }
                }
            }
        }
    }

    // MARK: Today

    /// What needs the person today, from their own modules: each count opens where to deal with it.
    @ViewBuilder
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Needs you today")
            if !digest.hasLoaded {
                LazyVGrid(columns: columns(min: 150), spacing: 10) {
                    ForEach(0..<4, id: \.self) { _ in
                        MetricCard(title: "Loading", value: "00", systemImage: "circle").redacted(reason: .placeholder)
                    }
                }
            } else if digest.signals.isEmpty {
                Label("Nothing is waiting for you. Nice work.", systemImage: "checkmark.circle.fill")
                    .font(.brandCallout)
                    .foregroundStyle(Tone.success.textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .brandCard(padding: 14, radius: 16)
                    .accessibilityIdentifier("home.allClear")
            } else {
                LazyVGrid(columns: columns(min: 150), spacing: 10) {
                    ForEach(digest.signals) { signal in
                        signalLink(signal)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func signalLink(_ signal: HomeSignal) -> some View {
        let card = MetricCard(title: signal.title, value: signal.count.formatted(), systemImage: signal.systemImage,
                              tone: signal.tone)
        Group {
            if let hub = signal.hub, hubs.contains(hub) {
                Button { open(.hub(hub)) } label: { card }
            } else if let destination = NativeModules.destination(forKey: signal.menuKey) {
                MenuDestinationLink(destination: destination) { card }
            } else {
                card
            }
        }
        .buttonStyle(.pressableCard)
        .accessibilityIdentifier("home.signal.\(signal.id)")
    }

    // MARK: Quick actions

    private struct QuickAction: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let color: Color
        /// A screen to push instead of running `run`.
        var destination: MenuDestination?
        var run: () -> Void = {}
    }

    private func actions(catalog: AppCatalog) -> [QuickAction] {
        var actions: [QuickAction] = []
        if case .menu(let chat)? = catalog.entry(forKey: AppMenu.aiChatKey)?.destination {
            actions.append(QuickAction(id: "ai", title: "Ask AI", systemImage: "sparkles",
                                       color: Palette.tileColors[1], destination: chat))
        }
        if let access = session.propertyDeals, PDWriteGates.canCapture(access, session.permissions) {
            actions.append(QuickAction(id: "capture", title: "Capture", systemImage: "camera.viewfinder",
                                       color: Palette.tileColors[0]) { showingCapture = true })
        }
        if session.permissions.can(.create, .fsServiceRequests) {
            actions.append(QuickAction(id: "request", title: "New request", systemImage: "plus.bubble",
                                       color: Palette.tileColors[3]) { creatingRequest = true })
        }
        actions.append(QuickAction(id: "apps", title: "Find app", systemImage: "magnifyingglass",
                                   color: Palette.tileColors[7]) { open(.apps) })
        return actions
    }

    private func quickActions(catalog: AppCatalog) -> some View {
        let items = actions(catalog: catalog)
        // Side by side, but two to a row at the largest text sizes so the names stay readable.
        let perRow = max(1, min(items.count, typeSize.isAccessibilitySize ? 2 : 4))
        return VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Quick actions")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: perRow),
                      spacing: 12) {
                ForEach(items) { action in
                    Group {
                        if let destination = action.destination {
                            MenuDestinationLink(destination: destination) { quickActionLabel(action) }
                        } else {
                            Button(action: action.run) { quickActionLabel(action) }
                        }
                    }
                    .buttonStyle(.pressableCard)
                    .accessibilityIdentifier("home.action.\(action.id)")
                }
            }
            .brandCard(padding: 14)
        }
    }

    private func quickActionLabel(_ action: QuickAction) -> some View {
        VStack(spacing: 8) {
            AppIconTile(systemImage: action.systemImage, color: action.color, size: 52)
            Text(action.title)
                .font(.brandCaption)
                .foregroundStyle(Color(.label))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Your apps

    private func appsSection(catalog: AppCatalog) -> some View {
        let entries = Array(catalog.nativeEntries.prefix(8))
        return VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Your apps") {
                Button("See all") { open(.apps) }
                    .accessibilityIdentifier("home.apps.all")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                                     count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 16) {
                ForEach(entries) { entry in
                    AppEntryLink(entry: entry) {
                        VStack(spacing: 8) {
                            AppIconTile(systemImage: entry.systemImage, color: entry.color, size: 56)
                            Text(entry.name)
                                .font(.brandCaption)
                                .foregroundStyle(Color(.label))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .contextMenu { PinToTabBarButton(pin: .app(entry.key)) }
                }
            }
            .brandCard(padding: 16)
        }
    }

    private func columns(min: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : min), spacing: 10)]
    }

}

// MARK: - Hero

/// The top of Home: the brand's dark surface with an accent glow, the date, a greeting in the
/// display face, the workspace, and the person's avatar (their profile and settings).
private struct HomeHero: View {
    @Binding var showingProfile: Bool
    @Binding var showingNotifications: Bool
    let unread: Int
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @State private var choosingWorkspace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                BrandMark(size: 30)
                    .padding(6)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
                Button { showingNotifications = true } label: {
                    Image(systemName: unread > 0 ? "bell.badge.fill" : "bell")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.12), in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if unread > 0 {
                                Text(unread > 99 ? "99+" : "\(unread)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.red, in: Capsule())
                                    .offset(x: 6, y: -4)
                            }
                        }
                }
                .accessibilityLabel(unread > 0 ? "Notifications, \(unread) unread" : "Notifications")
                .accessibilityIdentifier("home.notifications")
                Button { showingProfile = true } label: {
                    Text(session.user?.initials ?? "?")
                        .font(BrandFont.font(.semibold, size: 15, relativeTo: .subheadline))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 2))
                }
                .accessibilityLabel("Profile and settings")
                .accessibilityIdentifier("home.profile")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.brandEyebrow)
                    .tracking(1.4)
                    .foregroundStyle(Palette.onDarkMuted)
                Text(greeting)
                    .font(.brandHero)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            HStack(spacing: 8) {
                if let workspace = session.workspace {
                    Button {
                        choosingWorkspace = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "building.2")
                            Text(workspace.name).lineLimit(1)
                            Image(systemName: "chevron.down").imageScale(.small)
                        }
                        .font(.brandCaption)
                        .foregroundStyle(Palette.onDarkInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                    }
                    .accessibilityIdentifier("home.workspace")
                }
                if sync.pendingCount > 0 {
                    Pill(text: "\(sync.pendingCount) to sync", systemImage: "arrow.triangle.2.circlepath",
                         foreground: Palette.onDarkInk, background: .white.opacity(0.12))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Palette.heroGradient
                RadialGradient(colors: [Color.accentColor.opacity(0.55), .clear], center: .topTrailing,
                               startRadius: 10, endRadius: 260)
                RadialGradient(colors: [Palette.tileColors[1].opacity(0.35), .clear], center: .bottomLeading,
                               startRadius: 10, endRadius: 220)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.top, 8)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $choosingWorkspace) {
            NavigationStack { WorkspacePickerView(isInitialChoice: false) }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        guard let name = session.user?.firstName, !name.isEmpty else { return part }
        return "\(part),\n\(name)"
    }
}

// MARK: - Cards

/// The person's own hub: large, in its colour, with what it is for.
private struct PrimaryHubCard: View {
    let hub: NavigationPolicy.Home

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("START HERE")
                    .font(.brandEyebrow)
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.8))
                Text(hub.longTitle)
                    .font(.brandDisplay)
                    .foregroundStyle(.white)
                Text(hub.tagline)
                    .font(.brandSubheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: hub.systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Darkens toward the bottom so white text stays readable on every hub colour.
            ZStack {
                Palette.navy
                LinearGradient(colors: [hub.color, hub.color.opacity(0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .shadow(color: hub.color.opacity(0.3), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(hub.title)")
    }
}

/// Another hub with a tab: a smaller card.
private struct HubCard: View {
    let hub: NavigationPolicy.Home

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppIconTile(systemImage: hub.systemImage, color: hub.color, size: 38)
            Text(hub.longTitle)
                .font(.brandHeadline)
                .foregroundStyle(Color(.label))
            Text(hub.tagline)
                .font(.brandFootnote)
                .foregroundStyle(.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .brandCard(padding: 14, radius: 18)
        .accessibilityElement(children: .combine)
    }
}

/// The AI Navigator, offered at the foot of Home (its native chat screen).
private struct AssistantCardLabel: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(colors: [Color.accentColor, Palette.tileColors[1]],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask the AI Navigator")
                    .font(.brandHeadline)
                    .foregroundStyle(Color(.label))
                Text("Questions about customers, jobs, deals — in plain English.")
                    .font(.brandFootnote)
                    .foregroundStyle(.secondaryText)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
        }
        .brandCard(padding: 16)
    }
}

/// A role that opens nothing in this workspace: say so, and who can fix it.
struct NoAccessCard: View {
    /// The menu loaded, but nothing in it has a screen and there's no work area. A delivery partner
    /// has their deliveries, so it isn't "nothing" for them.
    static func applies(hasWorkspace: Bool, menuFailed: Bool, hasApps: Bool, hasWork: Bool,
                        isDeliveryPartner: Bool) -> Bool {
        hasWorkspace && !menuFailed && !hasApps && !hasWork && !isDeliveryPartner
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.circle")
                .font(.system(size: 34))
                .foregroundStyle(.secondaryText)
                .accessibilityHidden(true)
            Text("Nothing to show here yet")
                .font(.brandHeadline)
            Text("Your role doesn't give you access to anything in this workspace yet. Ask the person who manages "
                 + "it to give you a role for the work you do.")
                .font(.brandFootnote)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .brandCard(padding: 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.noAccess")
    }
}

/// The menu couldn't be loaded and there's no saved copy, so Home and Apps would be empty: say so,
/// and offer to try again.
struct MenuLoadFailedCard: View {
    @Environment(SessionStore.self) private var session
    @State private var retrying = false

    static func applies(hasWorkspace: Bool, error: APIError?, menuIsEmpty: Bool) -> Bool {
        hasWorkspace && error != nil && menuIsEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("We couldn't load your apps")
                .font(.brandHeadline)
                .accessibilityAddTraits(.isHeader)
            if retrying {
                ProgressView("Trying again…").padding(.vertical, 8)
            } else if let error = session.permissionsError {
                InlineErrorRow(error: error) {
                    Task {
                        retrying = true
                        await session.reloadPermissions()
                        retrying = false
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(padding: 16)
        .accessibilityIdentifier("home.menuFailed")
    }
}

/// With no navigation bar on Home, content scrolls under the clock and battery: a soft canvas
/// fade keeps them readable.
private struct StatusBarBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [Palette.canvas, Palette.canvas.opacity(0.85), Palette.canvas.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: proxy.safeAreaInsets.top + 12)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
