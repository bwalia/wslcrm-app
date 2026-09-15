import Foundation
import SwiftUI

/// Stateless API facades, injected through the environment.
struct Services: Sendable {
    let client: APIClient
    let fieldService: FieldServiceAPI
    let crm: CRMAPI
    let commerce: CommerceAPI
    let invoices: InvoicesAPI

    init(client: APIClient, cache: ResponseCache) {
        self.client = client
        fieldService = FieldServiceAPI(client: client, cache: cache)
        crm = CRMAPI(client: client)
        commerce = CommerceAPI(client: client)
        invoices = InvoicesAPI(client: client)
    }

    /// Used only as the environment default (previews); never talks to a real server.
    static let unconfigured: Services = {
        let client = APIClient(baseURL: URL(string: "https://example.invalid")!, tokenStore: InMemoryTokenStore())
        return Services(client: client, cache: ResponseCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-cache")))
    }()
}

extension EnvironmentValues {
    @Entry var services: Services = .unconfigured
}

/// Composition root: builds the object graph once per launch.
@MainActor
final class AppEnvironment {
    let config: AppConfig
    let client: APIClient
    let services: Services
    let connectivity: ConnectivityMonitor
    let sync: SyncCenter
    let session: SessionStore

    init(config: AppConfig, session urlSession: URLSession, tokenStore: TokenStore, cacheDirectory: URL,
         queueFile: URL, defaults: UserDefaults, monitorConnectivity: Bool) {
        self.config = config
        client = APIClient(baseURL: config.apiBaseURL, session: urlSession, tokenStore: tokenStore,
                           logger: NetworkLogger(isEnabled: config.networkLoggingEnabled))
        let cache = ResponseCache(directory: cacheDirectory)
        services = Services(client: client, cache: cache)
        connectivity = ConnectivityMonitor(startMonitoring: monitorConnectivity)
        let queue = MutationQueue(fileURL: queueFile, sender: client)
        sync = SyncCenter(queue: queue, client: client, connectivity: connectivity)
        session = SessionStore(auth: AuthAPI(client: client), client: client, cache: cache,
                               environmentName: config.environmentName, defaults: defaults)
        sync.currentUserId = { [weak session] in session?.user?.uuid }
    }

    /// `BGAppRefreshTask` handler: renews the signed-in engineer's offline copy of My Work.
    func refreshMyWorkInBackground() async {
        MyWorkRefresh.schedule()
        guard session.phase == .signedIn, session.permissions.can(.read, .fsVisits) else { return }
        let api = services.fieldService
        guard let fetched = try? await api.visits(MyWorkRefresh.query(now: Date())), !fetched.isFromCache else { return }
        await MyWorkRefresh.prefetchForOffline(fetched.value.items, api: api)
    }

    static func live() -> AppEnvironment {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(UITestSupport.launchArgument) {
            return UITestSupport.makeEnvironment()
        }
        if ProcessInfo.processInfo.arguments.contains("-WSLResetSession") {
            // Test runs start signed out with no cached data or queued writes.
            KeychainTokenStore().save(nil)
            try? FileManager.default.removeItem(at: ResponseCache.defaultDirectory())
            try? FileManager.default.removeItem(at: MutationQueue.defaultFileURL())
            if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        }
        #endif
        return AppEnvironment(config: .fromBundle(),
                              session: APIClient.makeSession(),
                              tokenStore: KeychainTokenStore(),
                              cacheDirectory: ResponseCache.defaultDirectory(),
                              queueFile: MutationQueue.defaultFileURL(),
                              defaults: .standard,
                              monitorConnectivity: true)
    }
}
