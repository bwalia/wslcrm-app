#if DEBUG
import Foundation

/// Launch-argument driven test harness (Debug builds only).
@MainActor
enum UITestSupport {
    static let launchArgument = "-UITestStubServer"

    static func makeEnvironment() -> AppEnvironment {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "uitest-\(UUID().uuidString)")!
        let config = AppConfig(apiBaseURL: URL(string: "https://stub.wslcrm.test")!, environmentName: "UITest",
                               networkLoggingEnabled: true)
        return AppEnvironment(config: config, session: URLSession(configuration: .ephemeral),
                              tokenStore: InMemoryTokenStore(), cacheDirectory: temp.appendingPathComponent("cache"),
                              queueFile: temp.appendingPathComponent("queue.json"), defaults: defaults,
                              monitorConnectivity: false)
    }
}
#endif
