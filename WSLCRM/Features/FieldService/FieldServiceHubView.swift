import SwiftUI

/// The Field Service area for managers and telecallers, as a dashboard: today's numbers (each opens what it counts),
/// then the work areas as cards (requests, jobs, visits, contracts, parts, assets, sites, job types, invoices) and the
/// Simpro report pack and sync.
struct FieldServiceHubView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var stats: LoadState<FieldServiceStats> = .idle
    @State private var creatingRequest = false
    @State private var createdRequest: ServiceRequestRoute?

    var body: some View {
        let permissions = session.permissions
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                // The page's main action, first; the Mac has it in the window's toolbar instead.
                if permissions.can(.create, .fsServiceRequests), !MacSupport.isMac {
                    Button {
                        creatingRequest = true
                    } label: {
                        Label("Log a service request", systemImage: "plus.bubble.fill")
                    }
                    .buttonStyle(.large(.info))
                    .accessibilityIdentifier("hub.newRequest")
                }
                if permissions.can(.read, .fsJobs) { today }

                section("Work", areas: workAreas(permissions))
                section("Simpro", areas: simproAreas(permissions))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .brandCanvas()
        .navigationTitle("Field Service")
        .toolbar {
            if MacSupport.isMac, permissions.can(.create, .fsServiceRequests) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Log a service request", systemImage: "plus.bubble") { creatingRequest = true }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("hub.newRequest")
                }
            }
        }
        .brandedNavigationBar()
        .task { await loadStats() }
        .wsRefreshable { await loadStats() }
        .sheet(isPresented: $creatingRequest) {
            ServiceRequestFormSheet(request: nil) { created in
                createdRequest = ServiceRequestRoute(uuid: created.request.uuid)
            }
        }
        .navigationDestination(item: $createdRequest) { ServiceRequestDetailView(requestUuid: $0.uuid) }
    }

    // MARK: Header

    /// The date, and the day in one line once the numbers are in.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                .font(.brandEyebrow)
                .tracking(1.2)
                .foregroundStyle(.secondaryText)
            Text(summary)
                .font(.brandTitle)
                .foregroundStyle(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var summary: String {
        guard let s = stats.value else { return "Requests, jobs and engineers on site" }
        var parts = ["\(s.visitsToday) \(s.visitsToday == 1 ? "visit" : "visits") today"]
        if s.engineersOnSite > 0 { parts.append("\(s.engineersOnSite) on site now") }
        if s.overdueJobs > 0 { parts.append("\(s.overdueJobs) \(s.overdueJobs == 1 ? "job" : "jobs") overdue") }
        if s.unassignedVisits > 0 {
            parts.append("\(s.unassignedVisits) \(s.unassignedVisits == 1 ? "visit needs" : "visits need") an engineer")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Today

    /// Today's numbers. Each card opens the jobs or visits it counts; what needs someone is coloured.
    @ViewBuilder
    private var today: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionHeader("Today")
            switch stats {
            case .idle, .loading:
                LazyVGrid(columns: tileColumns(4), spacing: 10) {
                    ForEach(0..<4, id: \.self) { _ in
                        MetricCard(title: "Loading", value: "00", systemImage: "circle").redacted(reason: .placeholder)
                    }
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await loadStats() } }
            case .loaded(let stats):
                let tiles = Self.tiles(stats)
                LazyVGrid(columns: tileColumns(tiles.count), spacing: 10) {
                    ForEach(tiles, id: \.title) { tile in
                        NavigationLink(value: tile.route) {
                            MetricCard(title: tile.title, value: "\(tile.count)", systemImage: tile.systemImage,
                                       tone: tile.count > 0 ? tile.tone : .brand, compact: sizeClass == .compact)
                        }
                        .buttonStyle(.pressableCard)
                        .accessibilityIdentifier("hub.stat.\(tile.title)")
                    }
                }
            }
        }
    }

    private struct Tile {
        let title: String
        let count: Int
        let systemImage: String
        let tone: Tone
        let route: AnyHashable
    }

    private static func tiles(_ s: FieldServiceStats) -> [Tile] {
        [
            Tile(title: "Visits today", count: s.visitsToday, systemImage: "calendar", tone: .info,
                 route: VisitsPresetRoute(preset: .today)),
            Tile(title: "On site now", count: s.engineersOnSite, systemImage: "mappin.and.ellipse", tone: .success,
                 route: VisitsPresetRoute(preset: .onSiteNow)),
            Tile(title: "Visits with no engineer", count: s.unassignedVisits,
                 systemImage: "person.crop.circle.badge.questionmark", tone: .warning,
                 route: VisitsPresetRoute(preset: .unassigned)),
            Tile(title: "Overdue", count: s.overdueJobs, systemImage: "exclamationmark.triangle", tone: .danger,
                 route: JobsPresetRoute(preset: .overdue)),
            Tile(title: "Open jobs", count: s.openJobs, systemImage: "wrench.and.screwdriver", tone: .brand,
                 route: JobsPresetRoute(preset: .open)),
            Tile(title: "In progress", count: s.inProgressJobs, systemImage: "arrow.triangle.2.circlepath",
                 tone: .progress, route: JobsPresetRoute(preset: .inProgress)),
            Tile(title: "Done, not invoiced", count: s.awaitingInvoice, systemImage: "doc.text", tone: .warning,
                 route: JobsPresetRoute(preset: .uninvoiced)),
        ]
    }

    /// Two a row on a phone; on an iPad or a Mac up to four, so a row is always full.
    private func tileColumns(_ count: Int) -> [GridItem] {
        if typeSize.isAccessibilitySize { return [GridItem(.adaptive(minimum: 280), spacing: 10)] }
        let perRow = sizeClass == .regular ? max(1, min(count, 4)) : 2
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: perRow)
    }

    // MARK: Areas

    private struct Area: Identifiable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
        let route: AnyHashable
    }

    private func workAreas(_ permissions: PermissionSet) -> [Area] {
        var areas: [Area] = []
        if permissions.shows(.serviceRequests) || permissions.can(.read, .fsJobs) {
            areas.append(Area(id: "hub.requests", title: "Service requests", detail: "Faults and visits customers ask for",
                              systemImage: "exclamationmark.bubble", route: FieldServiceArea.requests))
        }
        if permissions.shows(.jobs) {
            areas.append(Area(id: "hub.jobs", title: "Jobs", detail: "Work to do, its phases, parts and quotes",
                              systemImage: "wrench.and.screwdriver", route: FieldServiceArea.jobs))
        }
        if permissions.can(.read, .fsVisits) {
            areas.append(Area(id: "hub.visits", title: "Site visits", detail: "Who is where, today and this week",
                              systemImage: "calendar", route: NativeScreenRoute(FieldServiceScreens.visits)))
        }
        if permissions.can(.read, .fsContracts) {
            areas.append(Area(id: "hub.contracts", title: "Contracts", detail: "Maintenance plans and their visits",
                              systemImage: "doc.text.magnifyingglass", route: NativeScreenRoute(FieldServiceScreens.contracts)))
        }
        if permissions.can(.read, .fsParts) {
            areas.append(Area(id: "hub.parts", title: "Parts", detail: "Stock in the vans and the warehouse",
                              systemImage: "shippingbox", route: ResourceListRoute(ModuleCatalog.fsParts.id)))
        }
        if permissions.can(.read, .fsAssets) {
            areas.append(Area(id: "hub.customerAssets", title: "Assets", detail: "Customers' equipment and its history",
                              systemImage: "air.conditioner.horizontal", route: FieldServiceArea.customerAssets))
        }
        // The equipment models (store products) a request or job is raised against.
        areas.append(Area(id: "hub.assets", title: "Equipment models", detail: "The makes and models you service",
                          systemImage: "wrench.adjustable", route: FieldServiceArea.assets))
        areas.append(Area(id: "hub.sites", title: "Sites", detail: "Customers' addresses and access notes",
                          systemImage: "building.2", route: FieldServiceArea.sites))
        if permissions.can(.read, .fsJobTypes) || permissions.can(.read, .fsJobs) {
            areas.append(Area(id: "hub.jobTypes", title: "Job types", detail: "Phases, checklists and rates",
                              systemImage: "tag", route: NativeScreenRoute(FieldServiceScreens.jobTypes)))
        }
        if permissions.shows(.invoices) {
            areas.append(Area(id: "hub.invoices", title: "Invoices", detail: "Bills raised from finished jobs",
                              systemImage: "doc.text", route: FieldServiceArea.invoices))
        }
        return areas
    }

    private func simproAreas(_ permissions: PermissionSet) -> [Area] {
        var areas: [Area] = []
        if permissions.can(.read, .fsReports) {
            areas.append(Area(id: "hub.reports", title: "Reports", detail: "The Simpro report pack",
                              systemImage: "chart.bar.doc.horizontal", route: FieldServiceArea.reports))
        }
        if permissions.can(.read, .simproSync) {
            areas.append(Area(id: "hub.simpro", title: "Simpro sync", detail: "What came across from Simpro, and when",
                              systemImage: "arrow.triangle.2.circlepath.icloud", route: FieldServiceArea.simpro))
        }
        return areas
    }

    @ViewBuilder
    private func section(_ title: String, areas: [Area]) -> some View {
        if !areas.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DashboardSectionHeader(title)
                LazyVGrid(columns: areaColumns, spacing: 10) {
                    ForEach(Array(areas.enumerated()), id: \.element.id) { index, area in
                        NavigationLink(value: area.route) {
                            HubAreaCard(title: area.title, detail: area.detail, systemImage: area.systemImage,
                                        color: Palette.tileColors[index % Palette.tileColors.count])
                        }
                        .buttonStyle(.pressableCard)
                        .accessibilityIdentifier(area.id)
                    }
                }
            }
        }
    }

    /// One a row on a phone; on an iPad or a Mac as many 300 pt cards as fit.
    private var areaColumns: [GridItem] {
        sizeClass == .regular && !typeSize.isAccessibilitySize
            ? [GridItem(.adaptive(minimum: 300), spacing: 10)] : [GridItem(.flexible())]
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

/// A work area on a hub page: its icon, its name and what is in it, as a card that opens it.
struct HubAreaCard: View {
    let title: String
    let detail: String
    let systemImage: String
    var color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconTile(systemImage: systemImage, color: color, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.wsHeadline).foregroundStyle(Color(.label))
                Text(detail)
                    .font(.wsSubheadline)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(padding: 14, radius: 16)
        .accessibilityElement(children: .combine)
    }
}

/// Value-based routes for the Field Service area. Mixing destination-style links with value
/// routes in one stack makes SwiftUI re-push screens, so the area navigates by value only.
enum FieldServiceArea: Hashable {
    case requests, jobs, assets, sites, invoices
    case customerAssets, reports, simpro
    case projects, timesheets, myTasks, reviewQueue
}

struct AssetRoute: Hashable { let product: Product }
struct SiteRoute: Hashable { let site: FsSite }
