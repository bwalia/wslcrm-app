import SwiftUI

@main
struct WSLCRMApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        let environment = environment
        let appDelegate = appDelegate
        WindowGroup {
            RootView()
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
