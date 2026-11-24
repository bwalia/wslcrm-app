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

extension View {
    /// Pull to refresh on iPhone and iPad. A Mac has no pull, so there it is also a Refresh button with ⌘R.
    func wsRefreshable(action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(RefreshControl(action: action))
    }
}

private struct RefreshControl: ViewModifier {
    let action: @MainActor @Sendable () async -> Void

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .refreshable(action: action)
            .toolbar {
                ToolbarItem(placement: .automatic) { MacRefreshButton(action: action) }
            }
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
        .keyboardShortcut("r", modifiers: .command)
        .disabled(refreshing)
        .help("Refresh (⌘R)")
        .accessibilityIdentifier("mac.refresh")
    }
}
#endif
