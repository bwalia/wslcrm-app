import SwiftUI

/// The Mac's sidebar, in place of the phone's tab bar: the workspace at the top, Home, every work area, then every
/// app grouped as the web dashboard's sidebar groups them, and the person at the bottom. One click to anything.
struct MacSidebar: View {
    /// Something the person pinned to the top of the sidebar (right-click › Pin to sidebar), as on a phone's tab bar.
    struct Pinned: Identifiable {
        let pin: TabPin
        let title: String
        let systemImage: String
        let color: Color
        var id: String { pin.storageKey }
        var tab: AppTab {
            switch pin {
            case .hub(let hub): .hub(hub)
            case .app(let key): .app(key)
            }
        }
    }

    @Binding var selection: AppTab
    let pinned: [Pinned]
    let hubs: [NavigationPolicy.Home]
    let groups: [AppCatalog.Group]
    let failedCount: Int

    @Environment(SessionStore.self) private var session
    @State private var choosingWorkspace = false
    @State private var showingProfile = false
    /// "Filter menu…" at the top: narrows the sidebar to the matching items, as the web's sidebar does.
    @State private var filter = ""

    var body: some View {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let shows = { (title: String) in query.isEmpty || title.localizedCaseInsensitiveContains(query) }
        let starts: [(String, AppTab)] = [("Home", .home), ("All apps", .apps)].filter { shows($0.0) }
        let pinned = self.pinned.filter { shows($0.title) }
        let hubs = self.hubs.filter { shows($0.title) }
        let groups = AppCatalog.filter(self.groups, query)
        // Return opens the first match.
        let first = starts.first?.1 ?? pinned.first?.tab ?? hubs.first.map { .hub($0) }
            ?? groups.first?.entries.first.map { .app($0.key) }
        List(selection: Binding(get: { selection }, set: { if let tab = $0 { selection = tab } })) {
            if !starts.isEmpty {
                Section {
                    ForEach(starts, id: \.1) { title, tab in
                        tab == .home
                            ? row(title, systemImage: "house", tab: tab, tint: .accentColor, badge: failedCount)
                            : row(title, systemImage: "square.grid.2x2", tab: tab, tint: .secondary)
                    }
                }
            }
            if first == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing in the menu matches “\(query)”.")
                        .foregroundStyle(.secondaryText)
                    Button("Show the whole menu") { filter = "" }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.vertical, 4)
            }
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { item in
                        row(item.title, systemImage: item.systemImage, tab: item.tab, tint: item.color)
                            .contextMenu { PinToTabBarButton(pin: item.pin) }
                    }
                } header: { header("Pinned") }
            }
            if !hubs.isEmpty {
                Section {
                    ForEach(hubs, id: \.self) { hub in
                        row(hub.title, systemImage: hub.systemImage, tab: .hub(hub), tint: hub.color)
                            .contextMenu { PinToTabBarButton(pin: .hub(hub)) }
                    }
                } header: { header("Your work") }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        row(entry.name, systemImage: entry.systemImage, tab: .app(entry.key), tint: entry.color)
                            .contextMenu { PinToTabBarButton(pin: .app(entry.key)) }
                    }
                } header: { header(group.title) }
            }
        }
        .listStyle(.sidebar)
        .font(Self.rowFont)
        .environment(\.defaultMinListRowHeight, 30)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                workspaceHeader
                filterField { if let first { selection = first } }
            }
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { profileFooter }
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        .sheet(isPresented: $choosingWorkspace) {
            NavigationStack { WorkspacePickerView(isInitialChoice: false) }
        }
        .sheet(isPresented: $showingProfile) { ProfileSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .wsOpenSettings)) { _ in showingProfile = true }
        .accessibilityIdentifier("mac.sidebar")
    }

    // Sidebar sizes: smaller than the page's text, as in Apple's own Mac apps.
    static let rowFont = BrandFont.font(.medium, size: 14, relativeTo: .body)
    private static let headerFont = BrandFont.font(.semibold, size: 11, relativeTo: .caption)
    private static let titleFont = BrandFont.font(.semibold, size: 14, relativeTo: .headline)
    private static let detailFont = BrandFont.font(.medium, size: 11, relativeTo: .caption)

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Self.headerFont)
            .foregroundStyle(.secondaryText)
    }

    private func row(_ title: String, systemImage: String, tab: AppTab, tint: Color, badge: Int = 0) -> some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        // Inside the tag: a badge put on after it hid the tag from the List, so Home could never be selected again
        // once the person left it.
        .badge(badge)
        .tag(tab)
        .accessibilityIdentifier("sidebar.\(title)")
    }

    /// The workspace this window works in, and the way to another one.
    private var workspaceHeader: some View {
        Button { choosingWorkspace = true } label: {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.workspace?.name ?? "Workstation CRM")
                        .font(Self.titleFont)
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                    Text("Switch workspace")
                        .font(Self.detailFont)
                        .foregroundStyle(.secondaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch workspace")
        .accessibilityIdentifier("sidebar.workspace")
    }

    /// Narrows the menu as the person types; Return opens the first match, Escape clears it.
    private func filterField(open: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondaryText)
            TextField("Filter menu…", text: $filter)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(open)
                .onKeyPress(.escape) {
                    filter = ""
                    return .handled
                }
                .accessibilityIdentifier("sidebar.filter")
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the filter")
            }
        }
        .font(Self.rowFont)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Who is signed in: profile, settings and sign out.
    private var profileFooter: some View {
        Button { showingProfile = true } label: {
            HStack(spacing: 10) {
                Text(session.user?.initials ?? "?")
                    .font(Self.detailFont.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: Circle())
                Text(session.user?.displayName ?? "Your profile")
                    .font(Self.titleFont)
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help("Profile and settings")
        .accessibilityIdentifier("sidebar.profile")
    }
}
