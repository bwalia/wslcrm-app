import SwiftUI

@MainActor
@Observable
final class MyVisitsViewModel {
    enum Range: String, CaseIterable, Identifiable {
        case today = "Today"
        case upcoming = "Next 7 days"
        case recent = "Past 7 days"

        var id: String { rawValue }

        /// Local-calendar day boundaries, sent to the API as UTC instants.
        func interval(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date) {
            let startOfToday = calendar.startOfDay(for: now)
            switch self {
            case .today:
                return (startOfToday, calendar.date(byAdding: .day, value: 1, to: startOfToday)!)
            case .upcoming:
                return (startOfToday, calendar.date(byAdding: .day, value: 8, to: startOfToday)!)
            case .recent:
                return (calendar.date(byAdding: .day, value: -7, to: startOfToday)!, calendar.date(byAdding: .day, value: 1, to: startOfToday)!)
            }
        }
    }

    var range: Range = .today
    private(set) var state: LoadState<[Visit]> = .idle
    private(set) var cachedAt: Date?
    /// A refresh failure while older data is still on screen.
    private(set) var refreshError: APIError?

    private let api: FieldServiceAPI
    private let sync: SyncCenter
    private var prefetchTask: Task<Void, Never>?

    init(api: FieldServiceAPI, sync: SyncCenter) {
        self.api = api
        self.sync = sync
    }

    var visits: [Visit] { (state.value ?? []).map(displayed) }

    /// Visits grouped by local day, in schedule order.
    var sections: [(day: Date, visits: [Visit])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visits) { calendar.startOfDay(for: $0.scheduledStart ?? .distantPast) }
        return grouped.keys.sorted().map { day in
            (day, grouped[day]!.sorted { ($0.scheduledStart ?? .distantPast) < ($1.scheduledStart ?? .distantPast) })
        }
    }

    private var loadedRange: Range?

    func load() async {
        if state.value == nil || loadedRange != range {
            state = .loading
            cachedAt = nil
        }
        let requestedRange = range
        let interval = requestedRange.interval()
        do {
            let fetched = try await fetchVisits(range: requestedRange, interval: interval)
            guard requestedRange == range else { return }
            state = .loaded(fetched.value.items)
            loadedRange = requestedRange
            cachedAt = fetched.cachedAt
            refreshError = nil
            if !fetched.isFromCache { prefetchForOffline(fetched.value.items) }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value != nil {
                refreshError = apiError
            } else {
                state = .failed(apiError)
            }
        }
    }

    /// Network first. Offline with nothing cached for this exact range, falls back to the cached
    /// wider window (today ⊂ next 7 days) so an engineer who synced yesterday still sees today's visits.
    private func fetchVisits(range: Range, interval: (from: Date, to: Date)) async throws -> Fetched<Page<Visit>> {
        do {
            let fetched = try await api.visits(VisitListQuery(mine: true, from: interval.from, to: interval.to))
            if !fetched.isFromCache, range == .today {
                // Warm the week so tomorrow's "Today" also works offline.
                let week = Range.upcoming.interval()
                let api = self.api
                Task.detached(priority: .utility) { _ = try? await api.visits(VisitListQuery(mine: true, from: week.from, to: week.to)) }
            }
            return fetched
        } catch let error as APIError where error.isConnectivityProblem && range == .today {
            for wider in [Range.upcoming, .recent] {
                let window = wider.interval()
                if let cached = try? await api.visits(VisitListQuery(mine: true, from: window.from, to: window.to)) {
                    var page = cached.value
                    page.items = page.items.filter {
                        guard let start = $0.scheduledStart else { return false }
                        return start >= interval.from && start < interval.to
                    }
                    return Fetched(value: page, cachedAt: cached.cachedAt ?? Date.distantPast)
                }
            }
            // Yesterday's "Next 7 days" was keyed on yesterday's start-of-day; try that window too.
            let calendar = Calendar.current
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) {
                let window = Range.upcoming.interval(now: yesterday)
                if let cached = try? await api.visits(VisitListQuery(mine: true, from: window.from, to: window.to)) {
                    var page = cached.value
                    page.items = page.items.filter {
                        guard let start = $0.scheduledStart else { return false }
                        return start >= interval.from && start < interval.to
                    }
                    return Fetched(value: page, cachedAt: cached.cachedAt ?? Date.distantPast)
                }
            }
            throw error
        }
    }

    /// Visit status as the engineer last set it, including writes still waiting to sync.
    func displayed(_ visit: Visit) -> Visit {
        var copy = visit
        for mutation in sync.pending(for: visit.uuid) {
            switch mutation.kind {
            case .visitEnRoute: copy.status = .enRoute
            case .visitCheckIn: copy.status = .onSite
            case .visitCheckOut: copy.status = .completed
            case .visitNoAccess: copy.status = .noAccess
            default: break
            }
        }
        return copy
    }

    /// Caches the job (with phases) and visit detail for every open visit so they open offline.
    private func prefetchForOffline(_ visits: [Visit]) {
        prefetchTask?.cancel()
        let open = visits.filter { $0.status.isOpen }
        let jobIds = Array(Set(open.map(\.jobUuid).filter { !$0.isEmpty }))
        let visitIds = open.map(\.uuid)
        let api = self.api
        prefetchTask = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for id in jobIds {
                    if running >= 3 { await group.next(); running -= 1 }
                    group.addTask { _ = try? await api.job(id) }
                    running += 1
                }
                for id in visitIds {
                    if running >= 3 { await group.next(); running -= 1 }
                    group.addTask { _ = try? await api.visit(id) }
                    running += 1
                }
            }
        }
    }
}

struct MyVisitsView: View {
    @Environment(\.services) private var services
    @Environment(SyncCenter.self) private var sync
    @State private var model: MyVisitsViewModel?

    var body: some View {
        Group {
            if let model {
                MyVisitsContent(model: model)
            } else {
                SkeletonList()
            }
        }
        .navigationTitle("My Visits")
        .onAppear {
            if model == nil { model = MyVisitsViewModel(api: services.fieldService, sync: sync) }
        }
    }
}

private struct MyVisitsContent: View {
    @Bindable var model: MyVisitsViewModel
    @Environment(SyncCenter.self) private var sync

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $model.range) {
                    ForEach(MyVisitsViewModel.Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                if let cachedAt = model.cachedAt {
                    CachedDataNotice(savedAt: cachedAt)
                }
                if let error = model.refreshError {
                    InlineErrorRow(error: error) { Task { await model.load() } }
                }
            }

            ForEach(model.sections, id: \.day) { section in
                Section(section.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(section.visits) { visit in
                        NavigationLink(value: VisitRoute(uuid: visit.uuid)) {
                            VisitSummaryRow(visit: visit, showsJob: true,
                                            pending: !sync.pending(for: visit.uuid).isEmpty,
                                            failed: sync.pending(for: visit.uuid).contains(where: \.isFailed))
                        }
                        .accessibilityIdentifier("visits.row.\(visit.jobNumber)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            switch model.state {
            case .idle, .loading:
                SkeletonList()
            case .failed(let error):
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded(let visits) where visits.isEmpty:
                ContentUnavailableView {
                    Label("No visits", systemImage: "calendar.badge.checkmark")
                } description: {
                    Text(model.range == .today ? "You have nothing booked today." : "Nothing booked in this period.")
                } actions: {
                    if model.range == .today {
                        Button("Show next 7 days") { model.range = .upcoming }.buttonStyle(.bordered)
                    }
                }
            default:
                EmptyView()
            }
        }
        .refreshable { await model.load() }
        .task(id: model.range) { await model.load() }
        .onChange(of: sync.syncedGeneration) { _, _ in Task { await model.load() } }
    }
}

struct VisitSummaryRow: View {
    let visit: Visit
    var showsJob = true
    var pending = false
    var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let start = visit.scheduledStart {
                    Text(timeRange(start: start, end: visit.scheduledEnd))
                        .font(.headline.monospacedDigit())
                }
                Spacer()
                visit.status.badge
            }
            if showsJob {
                Text("\(visit.jobNumber) · \(visit.jobTitle)")
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
            } else if let engineer = visit.engineerName {
                Label(engineer, systemImage: "person.fill").font(.subheadline)
            }
            if showsJob, let customer = visit.customerName {
                Label(customer, systemImage: "person").font(.subheadline)
            }
            if let address = visit.fullAddress {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let phase = visit.phaseName {
                Label(phase, systemImage: "list.bullet.clipboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if pending { PendingSyncBadge(failed: failed) }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func timeRange(start: Date, end: Date?) -> String {
        let startText = start.formatted(date: .omitted, time: .shortened)
        guard let end else { return startText }
        return "\(startText) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}
