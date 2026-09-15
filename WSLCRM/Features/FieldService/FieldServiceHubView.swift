import SwiftUI

/// The Field Service area for managers and telecallers: today's numbers, then requests, jobs,
/// assets, sites and the invoices raised from jobs.
struct FieldServiceHubView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var stats: LoadState<FieldServiceStats> = .idle
    @State private var creatingRequest = false
    @State private var createdRequest: ServiceRequestRoute?

    var body: some View {
        let permissions = session.permissions
        List {
            if permissions.can(.read, .fsJobs) {
                Section {
                    switch stats {
                    case .idle, .loading:
                        SkeletonRow()
                    case .failed(let error):
                        InlineErrorRow(error: error) { Task { await loadStats() } }
                    case .loaded(let stats):
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                            StatTile(title: "Open jobs", value: "\(stats.openJobs)", systemImage: "wrench.and.screwdriver")
                            StatTile(title: "Visits today", value: "\(stats.visitsToday)", systemImage: "calendar")
                            StatTile(title: "On site now", value: "\(stats.engineersOnSite)", systemImage: "mappin.and.ellipse")
                            StatTile(title: "Overdue", value: "\(stats.overdueJobs)", systemImage: "exclamationmark.triangle")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if permissions.can(.create, .fsServiceRequests) {
                Section {
                    Button {
                        creatingRequest = true
                    } label: {
                        Label("Log a service request", systemImage: "plus.bubble.fill")
                    }
                    .buttonStyle(.large(.info))
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("hub.newRequest")
                }
            }

            Section {
                if permissions.shows(.serviceRequests) || permissions.can(.read, .fsJobs) {
                    NavigationLink(value: FieldServiceArea.requests) {
                        Label("Service requests", systemImage: "exclamationmark.bubble")
                    }
                    .accessibilityIdentifier("hub.requests")
                }
                if permissions.shows(.jobs) {
                    NavigationLink(value: FieldServiceArea.jobs) {
                        Label("Jobs", systemImage: "wrench.and.screwdriver")
                    }
                    .accessibilityIdentifier("hub.jobs")
                }
                NavigationLink(value: FieldServiceArea.assets) {
                    Label("Assets", systemImage: "wrench.adjustable")
                }
                .accessibilityIdentifier("hub.assets")
                NavigationLink(value: FieldServiceArea.sites) {
                    Label("Sites", systemImage: "building.2")
                }
                .accessibilityIdentifier("hub.sites")
                if permissions.shows(.invoices) {
                    NavigationLink(value: FieldServiceArea.invoices) {
                        Label("Invoices", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("hub.invoices")
                }
            }
        }
        .navigationTitle("Field Service")
        .task { await loadStats() }
        .refreshable { await loadStats() }
        .sheet(isPresented: $creatingRequest) {
            ServiceRequestFormSheet(request: nil) { created in
                createdRequest = ServiceRequestRoute(uuid: created.request.uuid)
            }
        }
        .navigationDestination(item: $createdRequest) { ServiceRequestDetailView(requestUuid: $0.uuid) }
    }

    private func loadStats() async {
        guard session.permissions.can(.read, .fsJobs) else { return }
        if stats.value == nil { stats = .loading }
        do {
            stats = .loaded(try await services.fieldService.stats())
        } catch {
            stats = .failed(error.asAPIError)
        }
    }
}

/// Value-based routes for the Field Service area. Mixing destination-style links with value
/// routes in one stack makes SwiftUI re-push screens, so the area navigates by value only.
enum FieldServiceArea: Hashable {
    case requests, jobs, assets, sites, invoices
}

struct AssetRoute: Hashable { let product: Product }
struct SiteRoute: Hashable { let site: FsSite }
