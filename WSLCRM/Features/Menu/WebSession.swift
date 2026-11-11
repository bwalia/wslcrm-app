import Foundation

/// A web dashboard page opened inside the app (`/dashboard/chat`).
struct WebPageRoute: Hashable, Sendable {
    let title: String
    let path: String
}

/// The web dashboard that goes with an API server.
enum DashboardURL {
    /// OpsAPI serves its dashboard next to the API with `-ui` added to the first part of the name
    /// (`int-opsapi.workstation.co.uk` → `int-opsapi-ui.workstation.co.uk`), and on port 8039 for a
    /// stack on this machine. nil when the API isn't named that way: there's no page to open.
    static func forAPI(_ api: URL) -> URL? {
        guard let host = api.host?.lowercased(), !host.isEmpty else { return nil }
        if APIEndpoint.isLocalHost(api) { return URL(string: "http://\(host):8039") }
        var labels = host.split(separator: ".").map(String.init)
        guard labels.count > 1, let first = labels.first, first.hasSuffix("opsapi") else { return nil }
        labels[0] = first + "-ui"
        return URL(string: "https://" + labels.joined(separator: "."))
    }

    /// `scheme://host[:port]`, as `window.location.origin` reports it.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }
}

/// What a web page needs to open signed in as this person, in this workspace.
struct WebSession: Sendable, Equatable {
    let dashboard: URL
    let accessToken: String
    let user: CurrentUser
    let workspace: Workspace

    /// The page's address on the dashboard.
    func url(for route: WebPageRoute) -> URL? {
        URL(string: route.path, relativeTo: dashboard)?.absoluteURL
    }

    /// Runs before the dashboard's own code and writes the sign-in and workspace the dashboard
    /// reads from its storage (`lib/api-client.ts`, the auth and namespace stores). It does
    /// nothing on any other origin, so the token never reaches another site.
    var bootstrapScript: String {
        let origin = DashboardURL.origin(of: dashboard) ?? ""
        var namespace: [String: Any] = ["uuid": workspace.uuid, "name": workspace.name]
        if let id = workspace.internalId { namespace["id"] = id }
        if let slug = workspace.slug { namespace["slug"] = slug }
        let person: [String: Any] = [
            "uuid": user.uuid, "email": user.email, "username": user.username ?? user.email,
            "first_name": user.firstName, "last_name": user.lastName,
        ]
        return """
        (function () {
          if (window.location.origin !== \(Self.json(origin))) { return; }
          try {
            var token = \(Self.json(accessToken)), user = \(Self.json(person)), ns = \(Self.json(namespace));
            localStorage.setItem('auth_token', token);
            localStorage.setItem('auth_user', JSON.stringify(user));
            localStorage.setItem('auth-storage', JSON.stringify({ state: { token: token, user: user, isAuthenticated: true }, version: 0 }));
            localStorage.setItem('current_namespace', JSON.stringify(ns));
            localStorage.setItem('namespace-storage', JSON.stringify({ state: { currentNamespace: ns }, version: 0 }));
            localStorage.removeItem('menu-storage');
          } catch (e) {}
        })();
        """
    }

    /// A JSON literal, which is also a safe JavaScript literal (quotes, backslashes and `</script>`
    /// are escaped).
    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}

/// Which addresses the in-app web page may load. Only the dashboard itself loads inside the app;
/// anything else opens in Safari (or Mail, Phone…), never with the person's session.
enum WebNavigation: Equatable {
    case allow
    /// The dashboard sent the page to its sign-in screen: the app signs it back in.
    case signInAgain
    case openOutside
    case block

    static func decide(_ url: URL?, dashboard: URL, isMainFrame: Bool) -> WebNavigation {
        guard let url, let scheme = url.scheme?.lowercased() else { return .block }
        // In-page content: blank frames, downloads built in the page, inline data.
        if ["about", "blob", "data"].contains(scheme) { return .allow }
        if !isMainFrame {
            // Embedded frames (maps, payment forms) don't get the sign-in script (main frame only).
            return scheme == "https" || (scheme == "http" && APIEndpoint.isLocalHost(url)) ? .allow : .block
        }
        if DashboardURL.origin(of: url) == DashboardURL.origin(of: dashboard) {
            return isSignInPage(url) ? .signInAgain : .allow
        }
        return ["http", "https", "mailto", "tel", "sms"].contains(scheme) ? .openOutside : .block
    }

    static func isSignInPage(_ url: URL) -> Bool {
        url.path == "/login" || url.path.hasPrefix("/login/")
    }
}
