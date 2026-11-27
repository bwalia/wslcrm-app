import SwiftUI
import UIKit

/// The Apps tab: everything in the workspace, from the server's menu (the same items, modules and
/// permissions as the web's sidebar), as an app launcher. Each group is a card, and every entry is a
/// native screen.
struct AppsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var search = ""
    @State private var records = RecordSearchModel()

    var body: some View {
        let catalog = AppCatalog(menu: session.menu)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if session.menu.isEmpty {
                    if MenuLoadFailedCard.applies(hasWorkspace: session.workspace != nil, error: session.permissionsError,
                                                  menuIsEmpty: true) {
                        MenuLoadFailedCard()
                    }
                    // No menu yet (offline on first launch): the apps the app knows, by permission.
                    VStack(alignment: .leading, spacing: 10) {
                        DashboardSectionHeader("Apps")
                        VStack(spacing: 0) { LegacyModuleLinks() }
                            .buttonStyle(.pressableCard)
                            .brandCard(padding: 8)
                    }
                } else {
                    let groups = catalog.filtered(search)
                    let searchingRecords = search.trimmingCharacters(in: .whitespaces).count >= RecordSearchModel.minimumLength
                    if catalog.groups.isEmpty {
                        NoAccessCard()
                    } else if groups.isEmpty, !searchingRecords || (records.groups.isEmpty && !records.isSearching
                                                                     && records.error == nil) {
                        ContentUnavailableView.search(text: search)
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            DashboardSectionHeader(group.title)
                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    AppEntryLink(entry: entry) { AppRow(entry: entry) }
                                        .contextMenu { PinToTabBarButton(pin: .app(entry.key)) }
                                    if index < group.entries.count - 1 {
                                        Divider().padding(.leading, 60)
                                    }
                                }
                            }
                            .brandCard(padding: 6, radius: 18)
                        }
                    }
                    // Customers, invoices, orders… matching the search (the web's ⌘K).
                    if searchingRecords {
                        RecordSearchResults(model: records, menu: session.menu) {
                            Task { await records.search(search, api: services.workspace()) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .brandCanvas()
        .navigationTitle("Apps")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search apps, customers, invoices…")
        .task(id: search) { await records.search(search, api: services.workspace()) }
        .wsRefreshable { await session.reloadPermissions() }
        .accessibilityIdentifier("apps.list")
    }
}

/// One app in a group card: its coloured icon and its name.
private struct AppRow: View {
    let entry: AppCatalog.Entry

    var body: some View {
        HStack(spacing: 14) {
            AppIconTile(systemImage: entry.systemImage, color: entry.color, size: 36)
            Text(entry.name)
                .font(.brandCallout)
                .foregroundStyle(Color(.label))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.wsFootnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// The person, their workspace, and the app: behind the avatar on Home.
struct ProfileSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                if let user = session.user {
                    Section {
                        VStack(spacing: 10) {
                            Text(user.initials)
                                .font(.brandDisplay)
                                .foregroundStyle(.white)
                                .frame(width: 84, height: 84)
                                .background(
                                    LinearGradient(colors: [Color.accentColor, Palette.indigo2],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: Circle())
                                .accessibilityHidden(true)
                            Text(user.displayName).font(.brandTitle)
                            Text(user.email).font(.brandSubheadline).foregroundStyle(.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                        .accessibilityElement(children: .combine)
                    }
                    Section("Workspace") {
                        NavigationLink {
                            WorkspacePickerView(isInitialChoice: false)
                        } label: {
                            LabeledContent {
                                Text(session.workspace?.name ?? "None")
                            } label: {
                                Label(session.workspaces.count > 1 ? "Switch workspace" : "Workspace",
                                      systemImage: "building.2")
                            }
                        }
                        .accessibilityIdentifier("more.workspace")
                        ForEach(session.menu.secondary) { item in
                            if let destination = MenuDestination.of(item) {
                                MenuDestinationLink(destination: destination) {
                                    Label(item.key == "settings" ? "Account settings" : item.name,
                                          systemImage: "slider.horizontal.3")
                                }
                                .accessibilityIdentifier("menu.item.\(item.key)")
                            }
                        }
                    }
                }
                Section("This device") {
                    if session.permissions.shows(.projects) || session.permissions.can(.read, .projects) {
                        // A value link: the queue pushes value routes, and a destination link in
                        // the same stack makes SwiftUI rebuild it (see `withAppDestinations`).
                        NavigationLink(value: FieldServiceArea.reviewQueue) {
                            Label("Waiting for me", systemImage: "person.crop.circle.badge.questionmark")
                        }
                        .accessibilityIdentifier("more.reviewQueue")
                    }
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
                        Label("App settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("more.settings")
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmingSignOut = true }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("more.signOut")
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            // The review queue opens tasks, projects and the rest from here.
            .withAppDestinations()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("profile.done")
                }
            }
            .confirmationDialog(signOutTitle, isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task { await session.signOut() }
                }
            } message: {
                if hasUnsynced {
                    Text("You have \(sync.mutations.count) change(s) that haven't been saved online yet. They stay on this device and are saved the next time you sign in.")
                }
            }
        }
    }

    private var hasUnsynced: Bool {
        guard let user = session.user else { return false }
        return sync.hasUnsyncedWrites(forUser: user.uuid)
    }

    private var signOutTitle: String {
        hasUnsynced ? "Sign out with unsynced changes?" : "Sign out of \(BrandStore.shared.brand.name)?"
    }
}

/// Screens reached from the Menu that have no route elsewhere in the app.
extension NativeScreen {
    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .crm: CRMHomeView()
        case .leads: LeadsHomeView()
        case .customers: CustomersListView()
        case .products: ProductsListView()
        case .orders: SalesOrdersView()
        case .shop: ShopHomeView()
        case .fieldService: FieldServiceHubView()
        case .propertyDealsToday: PDTodayView()
        }
    }
}

/// The modules the app knows, by permission — only used before the menu has ever loaded.
struct LegacyModuleLinks: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        let permissions = session.permissions
        if permissions.shows(.leads) {
            NavigationLink(value: NativeScreen.leads) { Label("Leads", systemImage: "person.crop.circle.badge.plus") }
        }
        if permissions.shows(.crm) {
            NavigationLink(value: NativeScreen.crm) { Label("CRM", systemImage: "person.2.crop.square.stack") }
        }
        if permissions.shows(.customers) {
            NavigationLink(value: NativeScreen.customers) { Label("Customers", systemImage: "person.crop.rectangle.stack") }
        }
        if permissions.shows(.products) {
            NavigationLink(value: NativeScreen.products) { Label("Products", systemImage: "shippingbox") }
        }
        if permissions.shows(.orders) {
            NavigationLink(value: NativeScreen.orders) { Label("Orders", systemImage: "cart") }
        }
        if permissions.shows(.invoices) {
            NavigationLink(value: FieldServiceArea.invoices) { Label("Invoices", systemImage: "doc.text") }
        }
        if permissions.shows(.purchaseOrders) {
            NavigationLink(value: PurchaseOrdersRoute()) { Label("Purchase orders", systemImage: "shippingbox.and.arrow.backward") }
        }
        if permissions.shows(.projects) || permissions.can(.read, .projects) {
            NavigationLink(value: FieldServiceArea.projects) { Label("Projects", systemImage: "square.stack.3d.up") }
        }
        NavigationLink(value: FieldServiceArea.timesheets) { Label("Timesheets", systemImage: "clock.badge.checkmark") }
    }
}
