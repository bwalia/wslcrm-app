import SwiftUI

/// Home: the first thing someone sees after signing in. A greeting, their work, today's numbers,
/// one-tap actions and their apps — a dashboard to start from and come back to, whatever the role.
struct HomeView: View {
    let hubs: [NavigationPolicy.Home]
    let open: (AppTab) -> Void
    /// Home's navigation stack: the command box opens screens and the assistant on it.
    @Binding var path: NavigationPath
    /// Bumped by ⌘K ("Ask AI…") to put the cursor in the command box.
    @Binding var focusRequest: Int

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
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
    @State private var lastRequest: String?
    @State private var agentBusy = false

    var body: some View {
        let catalog = AppCatalog(menu: session.menu)
        let wide = sizeClass == .regular && !typeSize.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HomeHeader(showingProfile: $showingProfile, showingNotifications: $showingNotifications,
                           unread: notifications.unread)
                if wide {
                    // A Mac or iPad window: the agent and today's work on the left, the launcher on the right.
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 24) { primaryColumn(catalog: catalog) }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 24) { secondaryColumn(catalog: catalog) }
                            .frame(width: 380, alignment: .topLeading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        primaryColumn(catalog: catalog)
                        secondaryColumn(catalog: catalog)
                    }
                }
            }
            .padding(.horizontal, wide ? 28 : 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 1440)
            .frame(maxWidth: .infinity)
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
            await notifications.load(services.workspace(), workspace: session.workspace?.uuid)
            await loadLastRequest()
        }
        .task(id: session.workspace?.uuid) {
            await digest.load(session: session, services: services)
            await invitations.load(services.workspace())
            await notifications.load(services.workspace(), workspace: session.workspace?.uuid)
            isDeliveryPartner = await MyDeliveries.isPartner(services)
        }
        // Each time Home comes back into view: the agent may have finished while the person was elsewhere.
        .onAppear { Task { await loadLastRequest() } }
        .sheet(isPresented: $showingNotifications) {
            NotificationsView(model: notifications)
                // A Mac sheet is small by default, which cramped the list.
                .frame(minWidth: MacSupport.isMac ? 560 : nil, idealWidth: MacSupport.isMac ? 620 : nil,
                       minHeight: MacSupport.isMac ? 620 : nil, idealHeight: MacSupport.isMac ? 760 : nil)
        }
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

    // MARK: Columns

    /// The agent, then what needs the person and their work.
    @ViewBuilder
    private func primaryColumn(catalog: AppCatalog) -> some View {
        CommandCenter(places: catalog.places, signals: digest.signals, canAsk: canAsk(catalog),
                      lastRequest: lastRequest, agentBusy: agentBusy, focusRequest: $focusRequest,
                      onOpen: { openPlace($0, catalog: catalog) },
                      onAsk: { ask($0) },
                      onContinue: { path.append(NativeScreenRoute(ChatAssistantRoute.screenID(path: nil))) })

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
        // New leads and customers who replied, first: the work that brings money in.
        if !digest.leadsReplied.isEmpty || !digest.leadsFresh.isEmpty {
            HomeLeadsPanel(replied: digest.leadsReplied, fresh: digest.leadsFresh)
        }
        if !HomeDigest.sources(session: session).isEmpty { todaySection }
        if !hubs.isEmpty { workSection }
    }

    /// One-tap actions and the launcher.
    @ViewBuilder
    private func secondaryColumn(catalog: AppCatalog) -> some View {
        quickActions(catalog: catalog)
        if !catalog.nativeEntries.isEmpty { appsSection(catalog: catalog) }
        if NoAccessCard.applies(hasWorkspace: session.workspace != nil, menuFailed: session.permissionsError != nil,
                                hasApps: !catalog.groups.isEmpty, hasWork: !hubs.isEmpty,
                                isDeliveryPartner: isDeliveryPartner) {
            NoAccessCard()
        }
    }

    // MARK: Command box

    private func canAsk(_ catalog: AppCatalog) -> Bool {
        catalog.entry(forKey: AppMenu.aiChatKey) != nil
    }

    private func openPlace(_ place: CommandRouter.Place, catalog: AppCatalog) {
        guard let entry = catalog.entry(forKey: place.key), case .menu(let destination) = entry.destination else { return }
        if entry.key == AppMenu.aiChatKey {
            path.append(NativeScreenRoute(ChatAssistantRoute.screenID(path: nil)))
        } else {
            path.append(ChatLinkTarget.menu(destination, title: entry.name))
        }
    }

    /// Hands a request to the all-round agent, on its own screen, where it is sent at once.
    private func ask(_ request: String) {
        path.append(NativeScreenRoute(ChatAssistantRoute.screenID(path: nil, ask: request)))
        lastRequest = request
        agentBusy = true
    }

    private func loadLastRequest() async {
        guard canAsk(AppCatalog(menu: session.menu)) else { return }
        guard let conversation = try? await ChatAPI(client: services.client).agentConversation(path: nil) else { return }
        lastRequest = conversation.turns.last(where: \.isUser)?.content.trimmedOrNil
        agentBusy = conversation.status == .running
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
                LazyVGrid(columns: tileColumns(others.count), spacing: 10) {
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
                LazyVGrid(columns: tileColumns(4), spacing: 10) {
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
                LazyVGrid(columns: tileColumns(digest.signals.count), spacing: 10) {
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
        let perRow = max(1, min(items.count, typeSize.isAccessibilitySize ? 2 : (sizeClass == .regular ? 3 : 4)))
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
        let entries = Array(catalog.nativeEntries.prefix(sizeClass == .regular ? 12 : 8))
        return VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Your apps") {
                Button("See all") { open(.apps) }
                    .accessibilityIdentifier("home.apps.all")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                                     count: typeSize.isAccessibilitySize ? 2 : (sizeClass == .regular ? 3 : 4)), spacing: 16) {
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

    /// Two a row on a phone; on an iPad or a Mac up to four, and fewer when there are fewer cards, so a row is
    /// always filled instead of a few tiles packed to the left of a wide window.
    private func tileColumns(_ count: Int) -> [GridItem] {
        if typeSize.isAccessibilitySize { return [GridItem(.adaptive(minimum: 280), spacing: 10)] }
        let perRow = count == 1 ? 1 : (sizeClass == .regular ? min(count, 4) : 2)
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: perRow)
    }

}

// MARK: - Header

/// The top line of Home, on the canvas: the brand, the date and a greeting, the workspace, notifications and the
/// person's avatar. Kept slim so the agent's box below it is the first thing the eye lands on.
private struct HomeHeader: View {
    @Binding var showingProfile: Bool
    @Binding var showingNotifications: Bool
    let unread: Int
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @State private var choosingWorkspace = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                identity
                Spacer(minLength: 12)
                workspaceButton
                controls
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    identity
                    Spacer(minLength: 8)
                    controls
                }
                workspaceButton
            }
        }
        .padding(.top, 12)
        .sheet(isPresented: $choosingWorkspace) {
            NavigationStack { WorkspacePickerView(isInitialChoice: false) }
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 12) {
            if !MacSupport.isMac { BrandMark(size: 34) }
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.brandEyebrow)
                    .tracking(1.2)
                    .foregroundStyle(.secondaryText)
                Text(greeting)
                    .font(.brandDisplay)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder
    private var workspaceButton: some View {
        HStack(spacing: 8) {
            if let workspace = session.workspace, !MacSupport.isMac {
                Button {
                    choosingWorkspace = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "building.2")
                        Text(workspace.name).lineLimit(1)
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                    .font(.brandFootnote)
                    .foregroundStyle(Color(.label))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.card, in: Capsule())
                    .overlay(Capsule().stroke(Palette.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.workspace")
            }
            if sync.pendingCount > 0 {
                Pill(text: "\(sync.pendingCount) to sync", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { showingNotifications = true } label: {
                Image(systemName: unread > 0 ? "bell.badge.fill" : "bell")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(.label))
                    .frame(width: 44, height: 44)
                    .background(Palette.card, in: Circle())
                    .overlay(Circle().stroke(Palette.hairline))
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
            .buttonStyle(.plain)
            .accessibilityLabel(unread > 0 ? "Notifications, \(unread) unread" : "Notifications")
            .accessibilityIdentifier("home.notifications")
            if !MacSupport.isMac {
            Button { showingProfile = true } label: {
                Text(session.user?.initials ?? "?")
                    .font(.brandCallout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile and settings")
            .accessibilityIdentifier("home.profile")
            }
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
        return "\(part), \(name)"
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

// MARK: - Leads waiting

/// Home's "Leads waiting for you": customers who replied (answer them) and new leads nobody has contacted, each
/// with what the AI made of them. A tap opens the lead, which leads with the next step: the email the AI wrote,
/// ready to check and send, or a call. Asks once for alerts, so the next lead rings the phone.
struct HomeLeadsPanel: View {
    let replied: [LeadCard]
    let fresh: [LeadCard]
    @Environment(PushCenter.self) private var push
    @AppStorage("home.leads.pushPromptDismissed") private var promptDismissed = false

    private static let limit = 5

    var body: some View {
        let rows = Array((replied.map { ($0, true) } + fresh.map { ($0, false) }).prefix(Self.limit))
        DashboardPanel(title: "Leads waiting for you") {
            Text(guide)
                .font(.wsFootnote)
                .foregroundStyle(.secondaryText)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rows, id: \.0.uuid) { lead, didReply in
                NavigationLink(value: LeadRoute(uuid: lead.uuid)) { row(lead, replied: didReply) }
                    .buttonStyle(.panelRow)
                    .accessibilityIdentifier("home.lead.\(lead.uuid)")
            }
            if replied.count + fresh.count > Self.limit {
                NavigationLink { LeadsHomeView() } label: {
                    PanelRow(title: "All \(replied.count + fresh.count) waiting", systemImage: "person.2")
                }
                .buttonStyle(.panelRow)
            }
            if push.authorization == .notDetermined, !promptDismissed { pushPrompt }
        }
        .task { await push.refreshAuthorization() }
        .accessibilityIdentifier("home.leads")
    }

    private var guide: String {
        if !replied.isEmpty {
            return replied.count == 1 ? "\(replied[0].name) replied. Open it to answer." : "\(replied.count) customers replied. Open one to answer."
        }
        return fresh.count == 1 ? "A new lead. Open it to send the email the AI wrote, or call them."
            : "\(fresh.count) new leads. Open one to send the email the AI wrote, or call them."
    }

    private func row(_ lead: LeadCard, replied: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(initials(lead.name))
                .font(.wsFootnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(replied ? Tone.success.solidColor : Tone.brand.solidColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(lead.name).font(.wsSubheadline.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(1)
                status(lead, replied: replied)
                Text(summary(lead))
                    .font(.wsFootnote)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(replied ? "Opens the lead to answer them" : "Opens the lead to get in touch")
    }

    /// "Replied 12 min ago" / "New · 40 min ago", in the row's colour.
    private func status(_ lead: LeadCard, replied: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: replied ? "arrowshape.turn.up.left.fill" : "sparkle").imageScale(.small)
            Text(replied ? "Replied" : "New")
            if let when = replied ? lead.lastReplyAt : lead.createdAt {
                Text(when, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
            }
        }
        .font(.wsCaption.weight(.semibold))
        .foregroundStyle(replied ? Tone.success.textColor : Tone.brand.textColor)
        .lineLimit(1)
    }

    private func summary(_ lead: LeadCard) -> String {
        if let summary = lead.aiSummary?.trimmedOrNil { return summary }
        let from = lead.source.map { "From \(Formatters.humanize($0).lowercased())" }
        return [lead.companyName, from].compactMap { $0 }.joined(separator: " · ").trimmedOrNil ?? "The AI is reading it now"
    }

    private func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var pushPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Get an alert the moment a lead comes in or replies.", systemImage: "bell.badge")
                .font(.wsSubheadline)
            HStack {
                Button("Turn on alerts") { Task { await push.requestPermission() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("home.leads.push.enable")
                Button("Not now") { promptDismissed = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
    }
}
