import Foundation

/// How a person's assigned cards turn into a day's work. Kept apart from the views so My Work,
/// My tasks and the tests all answer "what should I be doing today" the same way.
enum TaskAgenda {
    struct Bucket: Identifiable, Equatable {
        let id: String
        let title: String
        let tasks: [KanbanTask]
    }

    struct SprintBucket: Identifiable, Equatable {
        let sprint: KanbanSprint
        let tasks: [KanbanTask]
        var id: String { sprint.uuid }
    }

    /// Cards that are still somebody's job. The server already drops finished ones from
    /// `/my-tasks`; this keeps a card finished on this phone from lingering until the next load.
    static func open(_ tasks: [KanbanTask]) -> [KanbanTask] {
        tasks.filter { $0.status != .completed && $0.status != .cancelled }
    }

    /// Overdue, Today, This week, Later — by due date, nearest first.
    static func byDueDate(_ tasks: [KanbanTask], now: Date = Date(), calendar: Calendar = .current) -> [Bucket] {
        let today = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        func bucket(_ task: KanbanTask) -> Int {
            guard let due = task.dueDay(calendar: calendar) else { return 3 }
            if calendar.isDate(due, inSameDayAs: today) { return 1 }
            if due < today { return 0 }
            return due <= weekEnd ? 2 : 3
        }
        let ids = ["overdue", "today", "week", "later"]
        let titles = ["Overdue", "Today", "This week", "Later"]
        let open = open(tasks)
        return (0..<4).compactMap { index in
            let group = open.filter { bucket($0) == index }.sorted(by: dueFirst)
            return group.isEmpty ? nil : Bucket(id: ids[index], title: titles[index], tasks: group)
        }
    }

    /// What to work on today: anything overdue, anything due today, and anything already started.
    /// Overdue comes first because it is already late; then today's deadlines; then work in
    /// flight without one. Within each, the more urgent priority wins, then the nearer date.
    static func today(_ tasks: [KanbanTask], now: Date = Date(), calendar: Calendar = .current) -> [KanbanTask] {
        let today = calendar.startOfDay(for: now)
        func rank(_ task: KanbanTask) -> Int? {
            if let due = task.dueDay(calendar: calendar) {
                if calendar.isDate(due, inSameDayAs: today) { return 1 }
                if due < today { return 0 }
            }
            return task.status == .inProgress ? 2 : nil
        }
        return open(tasks)
            .compactMap { task in rank(task).map { (task, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.priority.urgency != rhs.0.priority.urgency {
                    return lhs.0.priority.urgency < rhs.0.priority.urgency
                }
                return dueFirst(lhs.0, rhs.0)
            }
            .map(\.0)
    }

    /// The cards in each running sprint, sprint ending soonest first. Within a sprint, work already
    /// started leads, because finishing beats starting when the sprint has an end date.
    static func bySprint(_ tasks: [KanbanTask], activeSprints: [Int: KanbanSprint]) -> [SprintBucket] {
        let grouped = Dictionary(grouping: open(tasks).filter { task in
            task.sprintId.map { activeSprints[$0] != nil } ?? false
        }, by: { $0.sprintId! })
        return grouped.compactMap { id, tasks in
            activeSprints[id].map { sprint in
                SprintBucket(sprint: sprint, tasks: tasks.sorted { lhs, rhs in
                    let lhsStarted = lhs.status == .inProgress, rhsStarted = rhs.status == .inProgress
                    if lhsStarted != rhsStarted { return lhsStarted }
                    if lhs.priority.urgency != rhs.priority.urgency { return lhs.priority.urgency < rhs.priority.urgency }
                    return dueFirst(lhs, rhs)
                })
            }
        }
        .sorted { ($0.sprint.endDate ?? .distantFuture, $0.sprint.name) < ($1.sprint.endDate ?? .distantFuture, $1.sprint.name) }
    }

    private static func dueFirst(_ lhs: KanbanTask, _ rhs: KanbanTask) -> Bool {
        (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
    }
}

extension KanbanTaskPriority {
    /// Lower is more urgent; the order the server sorts `/my-tasks` by.
    var urgency: Int {
        switch self {
        case .critical: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        case .none, .unknown: 4
        }
    }
}
