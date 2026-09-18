import Foundation

/// The server the app talks to, and the runtime override that can repoint it.
///
/// The build sets a default (`Config/*.xcconfig` → `WSLAPIBaseURL`). Pointing a build at
/// another environment — a demo against int, a bug reproduced on acc — otherwise needs a
/// rebuild, so the sign-in screen can store an override here. It survives relaunch and is
/// dropped by `useBuildDefault()`.
enum APIEndpoint {
    static let overrideKey = "WSLAPIBaseURLOverride"

    enum ValidationError: LocalizedError, Equatable {
        case empty
        case notAURL
        case insecure

        var errorDescription: String? {
            switch self {
            case .empty: "Enter the address of the API, e.g. https://int-opsapi.workstation.co.uk"
            case .notAURL: "That is not a valid address. It should look like https://int-opsapi.workstation.co.uk"
            case .insecure: "Use https. Plain http is only allowed for a local stack on this machine."
            }
        }
    }

    /// https anywhere; plain http only for a stack on this machine, which is the one case
    /// where there is no TLS to have.
    static func validate(_ text: String) throws -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else {
            throw ValidationError.notAURL
        }
        guard scheme == "https" || (scheme == "http" && isLocalHost(url)) else {
            throw ValidationError.insecure
        }
        return url
    }

    static func stored(in defaults: UserDefaults) -> URL? {
        guard let raw = defaults.string(forKey: overrideKey) else { return nil }
        return try? validate(raw)
    }

    static func save(_ url: URL?, to defaults: UserDefaults) {
        if let url {
            defaults.set(url.absoluteString, forKey: overrideKey)
        } else {
            defaults.removeObject(forKey: overrideKey)
        }
    }

    /// What the sign-in badge calls this server: the build's own label while it is the
    /// build's own server, otherwise the host, which is the only honest name for it.
    static func displayName(for url: URL, buildURL: URL, buildName: String) -> String {
        url == buildURL ? buildName : (url.host ?? "Custom")
    }

    static func isLocalHost(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost"].contains(url.host ?? "")
    }
}

/// Owns the live endpoint so the sign-in screen can change it: it repoints the client,
/// then throws away everything held for the previous server — tokens, cached responses and
/// the signed-in user are all meaningless against a different one.
@MainActor
@Observable
final class APIEndpointController {
    private(set) var current: URL
    let buildDefault: URL
    let buildName: String

    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: () -> SessionStore?

    var isOverridden: Bool { current != buildDefault }

    init(current: URL, buildDefault: URL, buildName: String, client: APIClient,
         defaults: UserDefaults, session: @escaping () -> SessionStore?) {
        self.current = current
        self.buildDefault = buildDefault
        self.buildName = buildName
        self.client = client
        self.defaults = defaults
        self.session = session
    }

    func use(_ url: URL) async {
        guard url != current else { return }
        APIEndpoint.save(url == buildDefault ? nil : url, to: defaults)
        current = url
        await client.setBaseURL(url)
        let name = APIEndpoint.displayName(for: url, buildURL: buildDefault, buildName: buildName)
        await session()?.resetForEndpointChange(environmentName: name)
    }

    func useBuildDefault() async {
        await use(buildDefault)
    }
}
