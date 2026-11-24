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
        CommandGroup(after: .textEditing) {
            Button("Ask AI…") { NotificationCenter.default.post(name: .wsAskAI, object: nil) }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}

extension Array where Element == GridItem {
    /// Stat tiles: two a row on a phone; on an iPad or a Mac as many as fit at 220 pt or wider, so a wide window
    /// doesn't stretch two tiles across it.
    static func tiles(_ sizeClass: UserInterfaceSizeClass?, spacing: CGFloat = 10) -> [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 220), spacing: spacing)]
            : [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)]
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

extension Notification.Name {
    /// "Ask AI" from anywhere (⌘K): Home's command box takes the focus.
    static let wsAskAI = Notification.Name("ws.askAI")
}

extension View {
    /// Keeps a scrolling screen (a `List` or `ScrollView`) to a readable column in a wide window, centred, instead of
    /// running rows edge to edge across a Mac display. No effect when the window is narrower than `maxWidth`.
    func wsReadableWidth(_ maxWidth: CGFloat = 1100) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth))
    }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, max(0, (width - maxWidth) / 2), for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
