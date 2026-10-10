import Foundation
import Observation
import os
import UIKit
import UserNotifications

/// `/api/v2/device-tokens`: native APNs tokens (opsapi `ios-apns-device-tokens`, Phase 3).
struct DeviceTokensAPI: Sendable {
    let client: APIClient

    struct Registration: Encodable, Sendable, Equatable {
        var token: String
        var tokenType = "apns"
        var apnsEnvironment: String
        var bundleId: String
        var deviceName: String
    }

    private struct Removal: Encodable, Sendable {
        var fcmToken: String
    }

    func register(_ registration: Registration) async throws {
        try await client.sendDiscardingBody(Endpoint(.post, "/api/v2/device-tokens", requiresNamespace: false)
            .withJSON(registration))
    }

    /// On sign-out, so this phone stops getting the person's alerts.
    func unregister(token: String) async throws {
        try await client.sendDiscardingBody(Endpoint(.delete, "/api/v2/device-tokens", requiresNamespace: false)
            .withJSON(Removal(fcmToken: token)))
    }
}

/// Push notifications: permission, the APNs token, and telling OpsAPI where to send.
///
/// Permission is only asked for when the person taps "Turn on alerts", never at launch. Once
/// allowed, the token is registered after every sign-in (the server keeps one row per token)
/// and removed at sign-out.
@MainActor
@Observable
final class PushCenter {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var token: String?

    @ObservationIgnored private let api: DeviceTokensAPI
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let environment: String
    @ObservationIgnored var isSignedIn: () -> Bool = { false }
    @ObservationIgnored private let log = Logger(subsystem: "uk.co.workstation.wslcrm", category: "push")

    private static let tokenKey = "apnsDeviceToken"

    init(api: DeviceTokensAPI, defaults: UserDefaults, environment: String) {
        self.api = api
        self.defaults = defaults
        self.environment = environment
        token = defaults.string(forKey: Self.tokenKey)
    }

    /// `development` for Debug builds, `production` for TestFlight and the App Store
    /// (the `aps-environment` entitlement, passed through Info.plist as `WSLAPNSEnvironment`).
    nonisolated static func environment(from bundle: Bundle = .main) -> String {
        let value = bundle.object(forInfoDictionaryKey: "WSLAPNSEnvironment") as? String
        return value == "production" ? "production" : "development"
    }

    var isAllowed: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Shows the system prompt (once); registers with APNs when allowed.
    func requestPermission() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// After sign-in: ask APNs for the token again (it answers from cache) if alerts are allowed.
    func registerIfAllowed() async {
        await refreshAuthorization()
        if isAllowed { UIApplication.shared.registerForRemoteNotifications() }
    }

    func didReceive(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = hex
        defaults.set(hex, forKey: Self.tokenKey)
        guard isSignedIn() else { return }
        Task { await sendToken(hex) }
    }

    func sendToken(_ hex: String) async {
        let registration = DeviceTokensAPI.Registration(token: hex, apnsEnvironment: environment,
                                                        bundleId: Bundle.main.bundleIdentifier ?? "uk.co.workstation.wslcrm",
                                                        deviceName: UIDevice.current.name)
        do {
            try await api.register(registration)
        } catch {
            log.error("Device token registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Before sign-out, while the session can still authenticate the call.
    func unregister() async {
        guard let token else { return }
        try? await api.unregister(token: token)
    }
}

/// Receives the APNs token and notification taps from UIKit.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let router = DeepLinkRouter()
    var push: PushCenter? {
        didSet {
            if let pendingToken, let push {
                push.didReceive(deviceToken: pendingToken)
                self.pendingToken = nil
            }
        }
    }
    private var pendingToken: Data?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        if let link = UITestPush.launchLink() { router.open(link) }
        if let url = UITestPush.launchURL() { router.open(url) }
        #endif
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        if let push { push.didReceive(deviceToken: deviceToken) } else { pendingToken = deviceToken }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger(subsystem: "uk.co.workstation.wslcrm", category: "push")
            .error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// In the foreground, still show the banner: an overdue task matters while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = AppDeepLink(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { router.open(link) }
    }
}

#if DEBUG
/// `-UITestPush '<payload json>'` behaves as if the person tapped that notification to launch the
/// app, so a UI test can follow a push without APNs.
enum UITestPush {
    static let launchArgument = "-UITestPush"
    /// `-UITestOpenURL <wslcrm://…>`: as if the link was opened from outside the app.
    static let urlArgument = "-UITestOpenURL"

    static func launchURL(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: urlArgument), index + 1 < arguments.count else { return nil }
        return URL(string: arguments[index + 1])
    }

    static func launchLink(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppDeepLink? {
        guard let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count,
              let data = arguments[index + 1].data(using: .utf8),
              let userInfo = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return AppDeepLink(userInfo: userInfo)
    }
}
#endif
