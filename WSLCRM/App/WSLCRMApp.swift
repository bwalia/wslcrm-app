import SwiftUI

@main
struct WSLCRMApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var environment = AppEnvironment.live()

    init() {
        BrandFont.register()
    }

    var body: some Scene {
        let environment = environment
        let appDelegate = appDelegate
        WindowGroup {
            RootView()
                .modifier(BrandBodyFont())
                .modifier(ThemeModifier())
                .environment(appDelegate.router)
                .environment(environment.push)
                .onAppear { appDelegate.push = environment.push }
                .environment(environment.session)
                .environment(environment.sync)
                .environment(environment.connectivity)
                .environment(environment.endpoint)
                .environment(\.services, environment.services)
        }
        .backgroundTask(.appRefresh(MyWorkRefresh.taskIdentifier)) {
            await environment.refreshMyWorkInBackground()
        }
    }
}

/// The brand's body face for every screen; styles that need another face set their own. With Bold
/// Text on (Settings › Accessibility) it steps up a weight, as the system font would.
private struct BrandBodyFont: ViewModifier {
    @Environment(\.legibilityWeight) private var legibilityWeight

    func body(content: Content) -> some View {
        content.font(legibilityWeight == .bold ? BrandFont.font(.semibold, size: 16, relativeTo: .body) : .brandBody)
    }
}
