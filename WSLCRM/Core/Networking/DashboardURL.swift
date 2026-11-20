import Foundation

/// The web dashboard host that goes with an API server. The app never opens its pages; it is only
/// where workspace files such as a logo stored as a path (`/brands/acme.png`) are served from.
enum DashboardURL {
    /// OpsAPI serves its dashboard next to the API with `-ui` added to the first part of the name
    /// (`int-opsapi.workstation.co.uk` → `int-opsapi-ui.workstation.co.uk`), and on port 8039 for a
    /// stack on this machine. nil when the API isn't named that way.
    static func forAPI(_ api: URL) -> URL? {
        guard let host = api.host?.lowercased(), !host.isEmpty else { return nil }
        if APIEndpoint.isLocalHost(api) { return URL(string: "http://\(host):8039") }
        var labels = host.split(separator: ".").map(String.init)
        guard labels.count > 1, let first = labels.first, first.hasSuffix("opsapi") else { return nil }
        labels[0] = first + "-ui"
        return URL(string: "https://" + labels.joined(separator: "."))
    }
}
