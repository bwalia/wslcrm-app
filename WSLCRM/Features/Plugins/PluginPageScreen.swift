import SwiftUI

/// Any plugin page (`/dashboard/plugins/<code>/<key>`), drawn natively: the server's description of
/// a generated page becomes a module kit list (search, filters, sorting, add, edit, delete), and a
/// plugin's own page the app has a screen for opens that screen.
struct PluginPageScreen: View {
    let code: String
    let key: String
    @Environment(\.services) private var services
    @State private var state: LoadState<PluginSchema> = .idle

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList()
            case .failed(let error):
                PluginPageProblem(error: error) { Task { await load() } }
            case .loaded(let schema):
                loaded(schema)
            }
        }
        .task { if state.value == nil { await load() } }
    }

    @ViewBuilder
    private func loaded(_ schema: PluginSchema) -> some View {
        if let screen = PluginPages.nativeScreen(code: schema.pluginCode, key: schema.key),
           let view = ModuleCatalog.screen(screen) {
            view
        } else if schema.kind == .resource {
            ResourceListView(PluginPageScreen.register(schema), title: schema.label)
        } else {
            ContentUnavailableView {
                Label(schema.label, systemImage: "puzzlepiece.extension")
            } description: {
                Text("This page is drawn by the \(schema.pluginName) plugin itself, and this version of the app "
                     + "has no screen for it yet. Everything else from \(schema.pluginName) in the menu works here.")
            }
            .navigationTitle(schema.label)
        }
    }

    /// Builds the page's descriptor and makes its records openable by id.
    static func register(_ schema: PluginSchema) -> ResourceDescriptor {
        let descriptor = PluginDescriptors.descriptor(from: schema)
        RuntimeDescriptors.register(descriptor)
        return descriptor
    }

    private func load() async {
        // Opened straight from the menu: a page the app draws itself needs no description first.
        if let screen = PluginPages.nativeScreen(code: code, key: key), ModuleCatalog.screen(screen) != nil {
            state = .loaded(PluginSchema(kind: .page, pluginCode: code, pluginName: code, apiPrefix: "", key: key,
                                         label: key, module: "", apiPath: "", fields: [], columns: [], filters: [],
                                         searchable: false, sortable: [], canCreate: false, canUpdate: false,
                                         canDelete: false))
            return
        }
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await PluginPagesAPI(client: services.client).schema(code: code, key: key))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

/// Reads a plugin page's description.
struct PluginPagesAPI: Sendable {
    let client: APIClient

    func schema(code: String, key: String) async throws -> PluginSchema {
        let path = "/api/v2/plugins/\(Self.escape(code))/resources/\(Self.escape(key))"
        let (data, _) = try await client.sendRaw(.get(path))
        guard let record = ResourceService.parseRecord(try ResourceService.decode(data), itemKey: nil, idKeys: []),
              let schema = PluginSchema(record) else {
            throw ResourceService.problem(404, "This page isn't available.")
        }
        return schema
    }

    static func escape(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? part
    }
}

/// Why a plugin page can't be shown, in plain words, with a way forward.
struct PluginPageProblem: View {
    let error: APIError
    let retry: () -> Void

    var body: some View {
        switch Self.reason(error) {
        case .forbidden:
            ContentUnavailableView {
                Label("You don't have access to this page", systemImage: "lock")
            } description: {
                Text("Ask a workspace admin to give your role access to it in the workspace's role settings.")
            }
        case .turnedOff(let message):
            ContentUnavailableView {
                Label("Turned off for this workspace", systemImage: "puzzlepiece.extension")
            } description: {
                Text("\(message). A workspace admin can turn it on under Workspace → Plugins.")
            }
        case .missing:
            ContentUnavailableView {
                Label("This page isn't available", systemImage: "puzzlepiece.extension")
            } description: {
                Text("The add-on that provides it isn't installed for this workspace, or no longer offers this page.")
            }
        case .other:
            ErrorStateView(error: error, retry: retry)
        }
    }

    enum Reason: Equatable { case forbidden, turnedOff(String), missing, other }

    static func reason(_ error: APIError) -> Reason {
        switch error {
        case .forbidden: return .forbidden
        case .notFound(let server):
            if server.code == "PLUGIN_DISABLED" { return .turnedOff(server.message) }
            return .missing
        default: return .other
        }
    }
}

/// The words of a plugin's validation answer (`{ error: "Validation failed", details: { field: msg } }`),
/// which the shared error type doesn't spell out field by field.
enum PluginProblem {
    static func message(_ error: APIError, labels: [String: String] = [:]) -> String {
        guard let server = error.serverError,
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(server.rawBody.utf8)),
              case .object(let top) = json, case .object(let details)? = top["details"], !details.isEmpty else {
            return error.localizedDescription
        }
        let parts = details.keys.sorted().compactMap { field -> String? in
            guard let text = details[field]?.stringValue else { return nil }
            // A full sentence stands alone; a fragment ("is required") gets its field's name.
            if let last = text.last, ".!?".contains(last) { return text }
            return "\(labels[field] ?? Formatters.humanize(field)): \(text)."
        }
        return parts.isEmpty ? error.localizedDescription : parts.joined(separator: " ")
    }
}
