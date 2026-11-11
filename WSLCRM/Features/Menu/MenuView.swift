import SwiftUI
import UIKit

/// The Menu tab: the web dashboard's sidebar on the phone. Same groups, same order, same items
/// for the same person and workspace — the server applies the workspace's modules and the
/// person's permissions. Items the app has a screen for open it; the rest open the web page,
/// signed in, inside the app.
struct MenuView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncCenter.self) private var sync
    @State private var confirmingSignOut = false
    @State private var search = ""

    var body: some View {
        List {
            if search.isEmpty { accountSection }

            if session.menu.isEmpty {
                // No menu yet (offline on first launch): the modules the app knows, by permission.
                Section("Modules") { LegacyModuleLinks() }
            } else {
                let sections = session.menu.filtered(search)
                let settings = search.isEmpty ? [] : session.menu.secondary.filter {
                    MenuItemLink.title(for: $0).localizedCaseInsensitiveContains(search)
                }
                if sections.isEmpty && settings.isEmpty {
                    Text("Nothing in your menu matches “\(search)”.")
                        .foregroundStyle(.secondaryText)
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { MenuItemLink(item: $0) }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
                if !settings.isEmpty {
                    Section { ForEach(settings) { MenuItemLink(item: $0) } }
                }
            }

            if search.isEmpty { appSection }
        }
        .navigationTitle("Menu")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search the menu")
        .refreshable { await session.reloadPermissions() }
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

    @ViewBuilder
    private var accountSection: some View {
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
                        Label(session.workspaces.count > 1 ? "Workspace · switch" : "Workspace",
                              systemImage: "building.2")
                    }
                }
                .accessibilityIdentifier("more.workspace")
            }
        }
    }

    @ViewBuilder
    private var appSection: some View {
        Section {
            ForEach(session.menu.secondary) { MenuItemLink(item: $0) }
            // The app's own queue of agent work to review (no web page): next to Projects.
            if session.permissions.shows(.projects) || session.permissions.can(.read, .projects) {
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
                .frame(minHeight: 44)
                .accessibilityIdentifier("more.signOut")
        }
    }

    private var hasUnsynced: Bool {
        guard let user = session.user else { return false }
        return sync.hasUnsyncedWrites(forUser: user.uuid)
    }

    private var signOutTitle: String {
        hasUnsynced ? "Sign out with unsynced changes?" : "Sign out of \(Brand.current.name)?"
    }
}

/// One menu row. Value links only: the screens behind them push further value routes, and a
/// destination link in the same list makes SwiftUI rebuild it (see `withAppDestinations`).
private struct MenuItemLink: View {
    let item: AppMenu.Item

    /// The web calls the workspace's settings just "Settings"; next to the app's own settings that
    /// needs saying.
    static func title(for item: AppMenu.Item) -> String {
        item.key == "settings" ? "Workspace settings" : item.name
    }

    var body: some View {
        switch MenuDestination.of(item) {
        case .screen(let screen): NavigationLink(value: screen) { label }.accessibilityIdentifier(identifier)
        case .area(let area): NavigationLink(value: area) { label }.accessibilityIdentifier(identifier)
        case .purchaseOrders: NavigationLink(value: PurchaseOrdersRoute()) { label }.accessibilityIdentifier(identifier)
        case .propertyDealsApprovals: NavigationLink(value: PDApprovalsRoute()) { label }.accessibilityIdentifier(identifier)
        case .propertyDealsRenovations: NavigationLink(value: PDRenovationsRoute()) { label }.accessibilityIdentifier(identifier)
        case .propertyPA(let manager): NavigationLink(value: PATodayRoute(manager: manager)) { label }.accessibilityIdentifier(identifier)
        case .web(let route): NavigationLink(value: route) { label }.accessibilityIdentifier(identifier)
        case nil: label.foregroundStyle(.secondaryText).accessibilityIdentifier(identifier)
        }
    }

    private var label: some View {
        Label(Self.title(for: item), systemImage: Self.symbol(item.icon))
    }

    private var identifier: String { "menu.item.\(item.key)" }

    /// The SF Symbol for the item's icon, checked so a name this iOS lacks never draws a blank.
    private static func symbol(_ lucide: String?) -> String {
        let name = MenuIcon.systemName(for: lucide)
        return UIImage(systemName: name) == nil ? MenuIcon.fallback : name
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
        case .orders: OrdersListView()
        case .shop: ShopHomeView()
        case .fieldService: FieldServiceHubView()
        case .propertyDealsToday: PDTodayView()
        }
    }
}

/// The modules the app knows, by permission — only used before the menu has ever loaded.
private struct LegacyModuleLinks: View {
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
