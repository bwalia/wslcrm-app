import SwiftUI

/// Every Property Deals screen opens through this, as the web's pages do: when the add-on is turned
/// off for the workspace it says so, and when nothing is set up yet it explains what it is and lets
/// a manager set it up (`POST /setup`) there and then.
struct PDAccessGate<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: Check = .checking
    @State private var settingUp = false
    @State private var setupError: APIError?

    enum Check: Equatable {
        case checking
        case off
        case notSetUp(canSetUp: Bool)
        case failed(String)
    }

    var body: some View {
        if session.propertyDeals != nil {
            content()
        } else {
            List {
                switch state {
                case .checking:
                    SkeletonRow()
                case .off:
                    ContentUnavailableView {
                        Label("Property Deals is turned off here", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("A workspace admin can turn it on for this workspace under Workspace → Plugins.")
                    }
                    .listRowBackground(Color.clear)
                case .notSetUp(let canSetUp):
                    notSetUp(canSetUp: canSetUp)
                case .failed(let message):
                    InlineErrorRow(error: ResourceService.problem(0, message)) { Task { await check() } }
                }
            }
            .navigationTitle("Property Deals")
            .task { await check() }
            .refreshable { await check() }
        }
    }

    @ViewBuilder
    private func notSetUp(canSetUp: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Property Deals isn’t in use here yet").font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                Text("It’s an add-on for buying, renovating and selling property. Nothing is set up for it in this workspace, so there’s nothing to show yet.")
                    .font(.wsSubheadline)
                Text("Looking for suppliers of goods or services? They’re under Shop → Suppliers and Purchase orders.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            .padding(.vertical, 4)
        }
        Section {
            if canSetUp {
                Text("Do you deal in property? Setting it up creates the deals board, the roles, the two workflow templates and the bank holidays.")
                    .font(.wsSubheadline)
                Button {
                    Task { await setUp() }
                } label: {
                    if settingUp { ProgressView() } else { Label("Set up Property Deals", systemImage: "wand.and.stars") }
                }
                .buttonStyle(.large())
                .disabled(settingUp)
                .accessibilityIdentifier("pd.setup")
                if let setupError { InlineErrorRow(error: setupError) }
            } else {
                Text("A manager can set it up if your business deals in property.").font(.wsSubheadline)
            }
        }
    }

    private func check() async {
        guard session.propertyDeals == nil else { return }
        do {
            let me = try await services.pdRaw.record("/me")
            if me.bool("setup_done") == false {
                let manage = me.strings("permissions.settings")
                state = .notSetUp(canSetUp: manage.contains("manage"))
            } else {
                // Set up, but the session hasn't caught up: load it again.
                await session.reloadPermissions()
                if session.propertyDeals == nil { state = .failed("Property Deals couldn’t be loaded. Pull to try again.") }
            }
        } catch {
            let apiError = error.asAPIError
            if case .notFound = apiError { state = .off; return }
            if case .forbidden = apiError {
                state = .failed("Your role can’t open Property Deals. Ask a workspace admin for access.")
                return
            }
            state = .failed(apiError.localizedDescription)
        }
    }

    private func setUp() async {
        settingUp = true
        defer { settingUp = false }
        do {
            try await services.pdRaw.send(.post, "/setup")
            setupError = nil
            await session.reloadPermissions()
            if session.propertyDeals == nil { await check() }
        } catch {
            setupError = error.asAPIError
        }
    }
}
