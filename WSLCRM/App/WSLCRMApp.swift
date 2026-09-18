import SwiftUI

@main
struct WSLCRMApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        let environment = environment
        WindowGroup {
            RootView()
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
