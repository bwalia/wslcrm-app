import SwiftUI

/// The Mac's sidebar, in place of the phone's tab bar: the workspace at the top, Home, every work area, then every
/// app grouped as the web dashboard's sidebar groups them, and the person at the bottom. One click to anything.
struct MacSidebar: View {
    @Binding var selection: AppTab
    let hubs: [NavigationPolicy.Home]
    let groups: [AppCatalog.Group]
    let failedCount: Int

    @Environment(SessionStore.self) private var session
    @State private var choosingWorkspace = false
    @State private var showingProfile = false

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let tab = $0 { selection = tab } })) {
            Section {
                row("Home", systemImage: "house", tab: .home, tint: .accentColor)
                    .badge(failedCount)
                row("All apps", systemImage: "square.grid.2x2", tab: .apps, tint: .secondary)
            }
            if !hubs.isEmpty {
                Section {
                    ForEach(hubs, id: \.self) { hub in
                        row(hub.title, systemImage: hub.systemImage, tab: .hub(hub), tint: hub.color)
                    }
                } header: { header("Your work") }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        row(entry.name, systemImage: entry.systemImage, tab: .app(entry.key), tint: entry.color)
                    }
                } header: { header(group.title) }
            }
        }
        .listStyle(.sidebar)
        .font(Self.rowFont)
        .environment(\.defaultMinListRowHeight, 30)
        .safeAreaInset(edge: .top, spacing: 0) { workspaceHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { profileFooter }
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        .sheet(isPresented: $choosingWorkspace) {
            NavigationStack { WorkspacePickerView(isInitialChoice: false) }
        }
        .sheet(isPresented: $showingProfile) { ProfileSheet() }
        .accessibilityIdentifier("mac.sidebar")
    }

    // Sidebar sizes: smaller than the page's text, as in Apple's own Mac apps.
    static let rowFont = BrandFont.font(.medium, size: 12.5, relativeTo: .body)
    private static let headerFont = BrandFont.font(.semibold, size: 10, relativeTo: .caption)
    private static let titleFont = BrandFont.font(.semibold, size: 12.5, relativeTo: .headline)
    private static let detailFont = BrandFont.font(.medium, size: 10, relativeTo: .caption)

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Self.headerFont)
            .foregroundStyle(.secondaryText)
    }

    private func row(_ title: String, systemImage: String, tab: AppTab, tint: Color) -> some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
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
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .help("Switch workspace")
        .accessibilityIdentifier("sidebar.workspace")
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
