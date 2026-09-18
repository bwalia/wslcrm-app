import SwiftUI

/// The engineer's home (opsapi #610 `/dashboard/field-service/my-work`): one big card for the
/// job in front of them, a today-at-a-glance summary, then the rest of the schedule.
@MainActor
@Observable
final class MyWorkViewModel {
    struct Bucket: Identifiable {
        let id: String
        let title: String
        let visits: [Visit]
        var isOverdue: Bool { id == "overdue" }
    }

    struct Summary: Equatable {
        var inProgress = 0
        var scheduledToday = 0
        var doneToday = 0
    }

    private(set) var state: LoadState<Void> = .idle
    private(set) var visits: [Visit] = []
    private(set) var cachedAt: Date?
    private(set) var refreshError: APIError?
    private(set) var unreadNotifications = 0
    private(set) var notifications: [AppNotification] = []
    /// Set when a background refresh finds a visit that wasn't there before.
    var newJobBanner: String?

    private let api: FieldServiceAPI
    private let sync: SyncCenter
    private let tracker: AssignmentTracker
    private let now: () -> Date
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var lastPrefetch: (ids: Set<String>, at: Date) = ([], .distantPast)

    init(api: FieldServiceAPI, sync: SyncCenter, userUuid: String, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.sync = sync
        self.tracker = AssignmentTracker(userUuid: userUuid)
        self.now = now
    }

    // MARK: Loading

    static func window(now: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
        MyWorkRefresh.window(now: now, calendar: calendar)
    }

    /// `silent` = background poll: no skeleton, errors kept out of the way, new jobs announced.
    func load(silent: Bool = false) async {
        if visits.isEmpty && !silent { state = .loading }
        do {
            let fetched = try await fetchVisits()
            let fresh = fetched.value.items
            if fetched.cachedAt == nil { prefetchForOffline(fresh) }
            if silent, fetched.cachedAt == nil {
                let added = tracker.newAssignments(in: fresh)
                if let first = added.first {
                    newJobBanner = added.count == 1 ? "New job assigned: \(first.jobTitle)" : "\(added.count) new jobs assigned"
                }
            }
            tracker.remember(fresh)
            visits = fresh
            cachedAt = fetched.cachedAt
            refreshError = nil
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if visits.isEmpty && !silent { state = .failed(apiError) } else { refreshError = apiError }
        }
        await loadNotifications()
    }

    private func fetchVisits() async throws -> Fetched<Page<Visit>> {
        do {
            return try await api.visits(MyWorkRefresh.query(now: now()))
        } catch let error as APIError where error.isConnectivityProblem {
            // Offline on a new day: yesterday's window still covers today.
            if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now()) {
                if let cached = try? await api.visits(MyWorkRefresh.query(now: yesterday)), cached.isFromCache {
                    return cached
                }
            }
            throw error
        }
    }

    /// Re-caches jobs and visit details when the open visits change, or every ten minutes —
    /// not on every 30-second poll.
    private func prefetchForOffline(_ visits: [Visit]) {
        let openIds = Set(visits.filter { $0.status.isOpen }.map(\.uuid))
        if openIds == lastPrefetch.ids, now().timeIntervalSince(lastPrefetch.at) < 600 { return }
        lastPrefetch = (openIds, now())
        prefetchTask?.cancel()
        let api = self.api
        prefetchTask = Task.detached(priority: .utility) {
            await MyWorkRefresh.prefetchForOffline(visits, api: api)
        }
    }

    func loadNotifications() async {
        guard let response = try? await api.notifications(limit: 30) else { return }
        notifications = response.notifications
        unreadNotifications = response.unreadCount
    }

    func markRead(_ notification: AppNotification) async {
        guard !notification.isRead else { return }
        try? await api.markNotificationRead(notification.id)
        await loadNotifications()
    }

    // MARK: Model (mirrors the dashboard's bucketing)

    /// Visit status including this engineer's writes still waiting to sync.
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

    var layout: (hero: Visit?, buckets: [Bucket], summary: Summary, total: Int) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var active: [Visit] = [], todayList: [Visit] = [], overdue: [Visit] = [], upcoming: [Visit] = []
        var summary = Summary()

        for raw in visits {
            let visit = displayed(raw)
            let start = visit.scheduledStart
            if visit.status == .completed, let start, start >= today, start < tomorrow { summary.doneToday += 1 }
            if visit.status == .completed || visit.status == .cancelled { continue }
            if visit.status == .enRoute || visit.status == .onSite { active.append(visit); continue }
            guard let start else { todayList.append(visit); continue }
            if start >= today && start < tomorrow { todayList.append(visit) }
            else if start < today { overdue.append(visit) }
            else { upcoming.append(visit) }
        }
        let byTime: (Visit, Visit) -> Bool = { ($0.scheduledStart ?? .distantPast) < ($1.scheduledStart ?? .distantPast) }
        active.sort(by: byTime); todayList.sort(by: byTime); overdue.sort(by: byTime); upcoming.sort(by: byTime)
        summary.inProgress = active.count
        summary.scheduledToday = todayList.count

        let hero = active.first ?? todayList.first ?? overdue.first ?? upcoming.first
        let buckets = [
            Bucket(id: "now", title: "In progress", visits: active),
            Bucket(id: "overdue", title: "Overdue", visits: overdue),
            Bucket(id: "today", title: "Later today", visits: todayList),
            Bucket(id: "upcoming", title: "Coming up", visits: upcoming),
        ]
        .map { Bucket(id: $0.id, title: $0.title, visits: $0.visits.filter { $0.uuid != hero?.uuid }) }
        .filter { !$0.visits.isEmpty }
        return (hero, buckets, summary, active.count + overdue.count + todayList.count + upcoming.count)
    }
}

/// Remembers which visits an engineer has already seen, to announce newly assigned jobs.
struct AssignmentTracker {
    let userUuid: String
    private var key: String { "knownVisitUuids.\(userUuid)" }

    func newAssignments(in visits: [Visit]) -> [Visit] {
        guard let known = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        let set = Set(known)
        return visits.filter { !set.contains($0.uuid) && $0.status.isOpen }
    }

    func remember(_ visits: [Visit]) {
        UserDefaults.standard.set(visits.map(\.uuid), forKey: key)
    }
}

struct GuidedVisitRoute: Hashable { let uuid: String }

struct MyWorkView: View {
    @Environment(\.services) private var services
    @Environment(SyncCenter.self) private var sync
    @Environment(SessionStore.self) private var session

    var body: some View {
        ModelHost(make: { MyWorkViewModel(api: services.fieldService, sync: sync, userUuid: session.user?.uuid ?? "") }) { model in
            MyWorkContent(model: model)
        }
        .navigationTitle("My Work")
        .brandedNavigationBar()
    }
}

private struct MyWorkContent: View {
    @Bindable var model: MyWorkViewModel
    @Environment(SyncCenter.self) private var sync
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingNotifications = false

    var body: some View {
        let layout = model.layout
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)

                if let banner = model.newJobBanner {
                    Button {
                        model.newJobBanner = nil
                    } label: {
                        Label(banner, systemImage: "bell.badge.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Tone.progress.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Tone.progress.color)
                    }
                    .accessibilityHint("Dismiss")
                    .accessibilityIdentifier("mywork.newJobBanner")
                }
                if let cachedAt = model.cachedAt {
                    CachedDataNotice(savedAt: cachedAt)
                }
                if let error = model.refreshError {
                    InlineErrorRow(error: error) { Task { await model.load() } }
                }

                switch model.state {
                case .idle, .loading:
                    SkeletonRow()
                    SkeletonRow()
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await model.load() } }
                case .loaded where layout.total == 0:
                    AllClearCard(doneToday: layout.summary.doneToday)
                case .loaded:
                    if let hero = layout.hero {
                        NavigationLink(value: GuidedVisitRoute(uuid: hero.uuid)) {
                            HeroCard(visit: hero, pending: !sync.pending(for: hero.uuid).isEmpty)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mywork.hero")
                    }
                    SummaryCard(summary: layout.summary)
                    ForEach(layout.buckets) { bucket in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(bucket.title) (\(bucket.visits.count))")
                                .font(.caption.weight(.bold))
                                .textCase(.uppercase)
                                .foregroundStyle(bucket.isOverdue ? Tone.danger.textColor : .secondaryText)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(bucket.visits) { visit in
                                NavigationLink(value: GuidedVisitRoute(uuid: visit.uuid)) {
                                    WorkRow(visit: visit, pending: !sync.pending(for: visit.uuid).isEmpty)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("mywork.row.\(visit.jobNumber)")
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNotifications = true
                } label: {
                    Image(systemName: model.unreadNotifications > 0 ? "bell.badge.fill" : "bell")
                        .symbolRenderingMode(.multicolor)
                }
                .accessibilityLabel(model.unreadNotifications > 0 ? "\(model.unreadNotifications) unread notifications" : "Notifications")
                .accessibilityIdentifier("mywork.notifications")
            }
        }
        .sheet(isPresented: $showingNotifications) {
            NotificationsSheet(model: model)
        }
        // Background refresh while on screen so newly assigned jobs appear (#610 polls every 30 s).
        .task {
            await model.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await model.load(silent: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load(silent: true) } }
        }
        .onChange(of: sync.syncedGeneration) { _, _ in Task { await model.load(silent: true) } }
    }
}

private struct HeroCard: View {
    let visit: Visit
    let pending: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let active = visit.status == .enRoute || visit.status == .onSite
        VStack(alignment: .leading, spacing: 12) {
            let heading = Text(active ? "Current job" : "Next up")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondaryText)
            let badges = Group {
                WorkStatusBadge(visit: visit)
                if visit.isUrgent {
                    StatusBadge(text: "Urgent", systemImage: "exclamationmark.2", tone: .danger)
                }
            }
            // One row normally; stacked at accessibility sizes, where three pills can't share it.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { heading; badges }
            } else {
                HStack(spacing: 8) { heading; badges }
            }
            Text(visit.jobTitle.isEmpty ? "Service visit" : visit.jobTitle)
                .font(.title.bold())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Text(visit.customerName ?? "No customer")
                .font(.title3)
                .foregroundStyle(.secondaryText)
            if let place = visit.siteName ?? visit.fullAddress {
                Label(place, systemImage: "mappin.and.ellipse")
                    .font(.body)
                    .foregroundStyle(.secondaryText)
            }
            if pending { PendingSyncBadge() }
            Label(active ? "Continue job" : visit.status == .noAccess ? "Revisit" : "Start job", systemImage: "arrow.right.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Engineer-friendly status wording (no workflow jargon).
struct WorkStatusBadge: View {
    let visit: Visit

    var body: some View {
        switch visit.status {
        case .onSite: StatusBadge(text: "On site now", systemImage: "mappin.and.ellipse", tone: .success)
        case .enRoute: StatusBadge(text: "On the way", systemImage: "car.fill", tone: .info)
        case .noAccess: StatusBadge(text: "No access — revisit", systemImage: "door.left.hand.closed", tone: .warning)
        case .completed: StatusBadge(text: "Done", systemImage: "checkmark.circle.fill", tone: .success)
        case .cancelled: StatusBadge(text: "Cancelled", systemImage: "xmark.circle", tone: .neutral)
        default: StatusBadge(text: Formatters.dateTime(visit.scheduledStart) ?? "Scheduled", systemImage: "calendar", tone: .neutral)
        }
    }
}

private struct SummaryCard: View {
    let summary: MyWorkViewModel.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today at a glance")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondaryText)
            HStack(spacing: 10) {
                SummaryTile(value: summary.inProgress, label: "In progress", tone: .success)
                SummaryTile(value: summary.scheduledToday, label: "Scheduled", tone: .neutral)
                SummaryTile(value: summary.doneToday, label: "Done today", tone: .neutral)
            }
        }
        .accessibilityIdentifier("mywork.summary")
    }
}

private struct SummaryTile: View {
    let value: Int
    let label: String
    let tone: Tone

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)").font(.largeTitle.bold().monospacedDigit()).foregroundStyle(tone == .neutral ? .primary : tone.textColor)
            Text(label).font(.footnote).foregroundStyle(.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 86)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

private struct WorkRow: View {
    let visit: Visit
    let pending: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    WorkStatusBadge(visit: visit)
                    if visit.isUrgent { StatusBadge(text: "Urgent", systemImage: "exclamationmark.2", tone: .danger) }
                }
                Text(visit.jobTitle.isEmpty ? "Service visit" : visit.jobTitle).font(.headline).foregroundStyle(.primary)
                Text([visit.customerName ?? "No customer", visit.siteName ?? visit.fullAddress].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondaryText).lineLimit(2)
                if pending { PendingSyncBadge() }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(14)
        .frame(minHeight: 80)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct AllClearCard: View {
    let doneToday: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Tone.success.color)
                .accessibilityHidden(true)
            Text("All clear").font(.title2.bold())
            Text(doneToday > 0 ? "No jobs waiting for you right now — \(doneToday) done today." : "No jobs waiting for you right now.")
                .foregroundStyle(.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct NotificationsSheet: View {
    @Bindable var model: MyWorkViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.notifications.isEmpty {
                    ContentUnavailableView("No notifications", systemImage: "bell.slash")
                }
                ForEach(model.notifications) { notification in
                    Button {
                        Task { await model.markRead(notification) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: notification.isRead ? "bell" : "bell.badge.fill")
                                .foregroundStyle(notification.isRead ? Color.secondary : Tone.progress.color)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(notification.title).font(notification.isRead ? .body : .headline).foregroundStyle(.primary)
                                if let message = notification.message { Text(message).font(.subheadline).foregroundStyle(.secondaryText) }
                                if let date = notification.createdAt {
                                    Text(Formatters.relative(date) ?? "").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityLabel("\(notification.isRead ? "" : "Unread. ")\(notification.title)")
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await model.loadNotifications() }
        }
    }
}
