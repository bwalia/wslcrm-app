import SwiftUI

@main
struct WSLCRMApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.session)
                .environment(environment.sync)
                .environment(environment.connectivity)
                .environment(\.services, environment.services)
        }
    }
}
