import CoreLocation
import Foundation

struct Coordinates: Sendable, Equatable, Codable {
    let latitude: Double
    let longitude: Double
}

/// One-shot location fix, requested only at the moment of check-in/check-out.
/// Never blocks the action: denial, restriction or timeout return `nil`.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func currentCoordinates(timeout: Duration = .seconds(8)) async -> Coordinates? {
        #if DEBUG
        // UI tests run against the stub server, where a system permission alert would block the
        // flow being tested. Check-in and check-out are designed to work without a fix anyway.
        if ProcessInfo.processInfo.arguments.contains(UITestSupport.launchArgument) { return nil }
        #endif
        guard CLLocationManager.locationServicesEnabled() else { return nil }

        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }

        let location: CLLocation? = await withCheckedContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
            // Never hold up the check-in: give up after `timeout`.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeLocation(nil)
            }
        }
        return location.map { Coordinates(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
    }

    private func resumeLocation(_ location: CLLocation?) {
        locationContinuation?.resume(returning: location)
        locationContinuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            self.authorizationContinuation?.resume(returning: status)
            self.authorizationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.resumeLocation(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resumeLocation(nil) }
    }
}
