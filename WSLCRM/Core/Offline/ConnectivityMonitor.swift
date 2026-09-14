import Foundation
import Network
import Observation

/// Publishes whether the device currently has a usable network path.
@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isOnline = true
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var onReconnect: [@MainActor () -> Void] = []

    init(startMonitoring: Bool = true) {
        if startMonitoring { start() }
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.update(online: online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "uk.co.workstation.wslcrm.connectivity"))
        self.monitor = monitor
    }

    func whenReconnected(_ action: @escaping @MainActor () -> Void) {
        onReconnect.append(action)
    }

    /// Test hook, also used by UI tests to simulate offline mode.
    func update(online: Bool) {
        let wasOffline = !isOnline
        isOnline = online
        if online && wasOffline {
            onReconnect.forEach { $0() }
        }
    }
}
