#if DEBUG
import Foundation

/// Debug-only "go offline for a while" switch, so a UI test can prove the offline promise:
/// a write made with no signal is queued, shown as waiting, and sent when the signal returns.
///
/// Enable with `-WSLOfflineWindow <startSeconds>,<endSeconds>` (relative to launch). Every
/// request inside the window fails the way a real loss of connectivity does. Compiled out of
/// Release builds.
enum OfflineSimulator {
    static let launchArgument = "-WSLOfflineWindow"

    /// Parsed window, or nil when the argument is absent or malformed.
    static func window(arguments: [String] = ProcessInfo.processInfo.arguments) -> ClosedRange<TimeInterval>? {
        guard let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count else { return nil }
        let parts = arguments[index + 1].split(separator: ",").compactMap { TimeInterval($0) }
        guard parts.count == 2, parts[0] <= parts[1] else { return nil }
        return parts[0]...parts[1]
    }

    static func install(window: ClosedRange<TimeInterval>, on configuration: URLSessionConfiguration) {
        OfflineURLProtocol.window = window
        OfflineURLProtocol.launchedAt = Date()
        configuration.protocolClasses = [OfflineURLProtocol.self] + (configuration.protocolClasses ?? [])
    }
}

final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var window: ClosedRange<TimeInterval> = 0...0
    nonisolated(unsafe) static var launchedAt = Date()

    private static var isOffline: Bool {
        window.contains(Date().timeIntervalSince(launchedAt))
    }

    override class func canInit(with request: URLRequest) -> Bool { isOffline }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
#endif
