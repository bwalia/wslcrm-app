import Foundation

/// Build-configuration values injected through `Config/*.xcconfig` → Info.plist.
struct AppConfig: Sendable, Equatable {
    let apiBaseURL: URL
    let environmentName: String
    /// What the build itself ships with, kept so the sign-in screen can offer a way back
    /// after someone repoints the app at another environment.
    let buildAPIBaseURL: URL
    let buildEnvironmentName: String
    /// Request/response logging. On in Debug builds, or when launched with `-WSLNetworkLogging YES`.
    let networkLoggingEnabled: Bool

    static func fromBundle(_ bundle: Bundle = .main, defaults: UserDefaults = .standard) -> AppConfig {
        guard
            let raw = bundle.object(forInfoDictionaryKey: "WSLAPIBaseURL") as? String,
            !raw.isEmpty,
            let url = URL(string: raw),
            url.scheme == "https" || (url.scheme == "http" && isLocalHost(url)
                && bundle.object(forInfoDictionaryKey: "WSLAPIEnvironmentName") as? String == "Local")
        else {
            // The build phase "Validate API base URL" should make this unreachable.
            fatalError("WSLAPIBaseURL is missing or invalid. Check Config/*.xcconfig (see README).")
        }
        let name = bundle.object(forInfoDictionaryKey: "WSLAPIEnvironmentName") as? String ?? "Unknown"
        #if DEBUG
        let logging = true
        #else
        let logging = defaults.bool(forKey: "WSLNetworkLogging")
        #endif
        // A tester can repoint the app from the sign-in screen; that choice outranks the
        // build's own default until it is cleared.
        let effective = APIEndpoint.stored(in: defaults) ?? url
        return AppConfig(apiBaseURL: effective,
                         environmentName: APIEndpoint.displayName(for: effective, buildURL: url, buildName: name),
                         buildAPIBaseURL: url,
                         buildEnvironmentName: name,
                         networkLoggingEnabled: logging)
    }

    /// Plain http is accepted only for the Local (Docker) configuration.
    private static func isLocalHost(_ url: URL) -> Bool {
        APIEndpoint.isLocalHost(url)
    }
}
