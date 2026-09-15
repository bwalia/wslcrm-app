import BackgroundTasks
import Foundation

/// Keeps an engineer's schedule usable offline. My Work pre-caches the job (with phases) and visit
/// detail behind every open visit, and a `BGAppRefreshTask` renews that copy while the app is in
/// the background, so the day's work still opens in a basement plant room with no signal.
enum MyWorkRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "uk.co.workstation.wslcrm.mywork-refresh"

    /// The window #610 uses: three days back (overdue) to three weeks ahead.
    static func window(now: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
        let today = calendar.startOfDay(for: now)
        return (calendar.date(byAdding: .day, value: -3, to: today)!, calendar.date(byAdding: .day, value: 21, to: today)!)
    }

    /// The single query My Work and the background refresh share, so both hit the same cache entry.
    static func query(now: Date) -> VisitListQuery {
        let window = window(now: now)
        return VisitListQuery(mine: true, from: window.from, to: window.to, perPage: 200)
    }

    /// Caches the job and visit detail for every open visit, three requests at a time.
    static func prefetchForOffline(_ visits: [Visit], api: FieldServiceAPI) async {
        let open = visits.filter { $0.status.isOpen }
        let jobIds = Array(Set(open.map(\.jobUuid).filter { !$0.isEmpty }))
        let visitIds = open.map(\.uuid)
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

    /// Asks the system for a refresh in about half an hour (it decides when, or whether, to run).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)   // unavailable on the Simulator; not an error
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }
}
