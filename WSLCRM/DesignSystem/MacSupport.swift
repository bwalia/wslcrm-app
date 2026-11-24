import SwiftUI

// The Mac app (Mac Catalyst, "Optimize Interface for Mac"): the same screens as iPhone and iPad, with what a Mac
// lacks made up for here. Everything in this file is a no-op on iPhone and iPad.

enum MacSupport {
    /// True in the Mac app.
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// Below this the screens' two-column layouts and forms get cramped.
    static let minimumWindowSize = CGSize(width: 720, height: 560)

    /// Stops windows being dragged smaller than `minimumWindowSize`.
    @MainActor static func applyWindowLimits() {
        #if targetEnvironment(macCatalyst)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = minimumWindowSize
        }
        #endif
    }
}

/// The screen in front's refresh, for the Mac menu's View › Refresh (⌘R). Each refreshable screen registers while it is
/// on screen; the last one to appear is the one in front (a pushed screen, the selected tab).
@MainActor
final class MacRefreshCenter {
    static let shared = MacRefreshCenter()
    private var screens: [(id: UUID, action: @MainActor @Sendable () async -> Void)] = []

    func appeared(_ id: UUID, action: @escaping @MainActor @Sendable () async -> Void) {
        screens.removeAll { $0.id == id }
        screens.append((id, action))
    }

    func disappeared(_ id: UUID) {
        screens.removeAll { $0.id == id }
    }

    func refresh() {
        guard let action = screens.last?.action else { return }
        Task { await action() }
    }
}

/// The Mac menu bar's commands.
struct MacCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh") { MacRefreshCenter.shared.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}

extension View {
    /// Pull to refresh on iPhone and iPad. A Mac has no pull, so there it is a Refresh button and View › Refresh (⌘R).
    func wsRefreshable(action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(RefreshControl(action: action))
    }
}

private struct RefreshControl: ViewModifier {
    let action: @MainActor @Sendable () async -> Void
    @State private var id = UUID()

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .refreshable(action: action)
            .toolbar {
                ToolbarItem(placement: .automatic) { MacRefreshButton(action: action) }
            }
            .onAppear { MacRefreshCenter.shared.appeared(id, action: action) }
            .onDisappear { MacRefreshCenter.shared.disappeared(id) }
        #else
        content.refreshable(action: action)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct MacRefreshButton: View {
    let action: @MainActor @Sendable () async -> Void
    @State private var refreshing = false

    var body: some View {
        Button {
            refreshing = true
            Task {
                await action()
                refreshing = false
            }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(refreshing)
        .help("Refresh (⌘R)")
        .accessibilityIdentifier("mac.refresh")
    }
}
#endif
