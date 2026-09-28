import XCTest
@testable import WSLCRM

/// What "today" and "this sprint" mean for someone's assigned cards. Both My Work and My tasks
/// answer from these rules, so a card that is late never hides behind one that merely matters.
final class TaskAgendaTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 9))!

    private func day(_ offset: Int) -> String {
        let date = calendar.date(byAdding: .day, value: offset, to: now)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private func task(_ uuid: String, status: String = "open", priority: String = "none",
                      due: Int? = nil, sprint: Int? = nil, project: String = "p1") throws -> KanbanTask {
        var fields = [#""uuid": "\#(uuid)""#, #""title": "\#(uuid)""#, #""status": "\#(status)""#,
                      #""priority": "\#(priority)""#, #""project_uuid": "\#(project)""#]
        if let due { fields.append(#""due_date": "\#(day(due))""#) }
        if let sprint { fields.append(#""sprint_id": \#(sprint)"#) }
        return try JSONDecoder.opsAPI().decode(KanbanTask.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func sprint(_ id: Int, name: String, status: String = "active", endsIn: Int) throws -> KanbanSprint {
        let json = """
        {"uuid": "s\(id)", "id": \(id), "name": "\(name)", "status": "\(status)",
         "end_date": "\(day(endsIn))", "task_count": 6, "completed_count": 2}
        """
        return try JSONDecoder.opsAPI().decode(KanbanSprint.self, from: Data(json.utf8))
    }

    // MARK: Today

    func testTodayIsWhatIsLateThenWhatIsDueThenWhatIsAlreadyStarted() throws {
        let tasks = [
            try task("started", status: "in_progress", due: 5),
            try task("due-today", due: 0),
            try task("late", due: -2),
            try task("next-week", due: 6),
            try task("no-date"),
        ]
        let today = TaskAgenda.today(tasks, now: now, calendar: calendar).map(\.uuid)
        XCTAssertEqual(today, ["late", "due-today", "started"],
                       "cards due later and not started are tomorrow's problem")
    }

    /// `due_date` is a date column, so it arrives as "2026-09-28" and decodes as midnight UTC.
    func testADateOnlyDeadlineIsTheSameDayWhereverThePhoneIs() throws {
        let json = #"{"uuid": "t", "title": "t", "due_date": "2026-09-28"}"#
        let card = try JSONDecoder.opsAPI().decode(KanbanTask.self, from: Data(json.utf8))
        for zone in ["Europe/London", "America/New_York", "Asia/Kolkata"] {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = TimeZone(identifier: zone)!
            let morning = local.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 9))!
            XCTAssertEqual(TaskAgenda.today([card], now: morning, calendar: local).count, 1,
                           "due today in \(zone), not yesterday or overdue")
        }
    }

    func testWithinTodayTheMoreUrgentCardLeads() throws {
        let tasks = [try task("low", priority: "low", due: 0), try task("critical", priority: "critical", due: 0)]
        XCTAssertEqual(TaskAgenda.today(tasks, now: now, calendar: calendar).map(\.uuid), ["critical", "low"])
    }

    func testAFinishedCardLeavesTodayEvenBeforeTheNextLoad() throws {
        let tasks = [try task("done", status: "completed", due: 0), try task("dropped", status: "cancelled", due: -1)]
        XCTAssertTrue(TaskAgenda.today(tasks, now: now, calendar: calendar).isEmpty)
    }

    func testByDueDateStillGroupsEverything() throws {
        let tasks = [try task("late", due: -1), try task("today", due: 0), try task("soon", due: 3),
                     try task("someday")]
        let buckets = TaskAgenda.byDueDate(tasks, now: now, calendar: calendar)
        XCTAssertEqual(buckets.map(\.title), ["Overdue", "Today", "This week", "Later"])
        XCTAssertEqual(buckets.flatMap(\.tasks).count, 4)
    }

    // MARK: Sprint

    func testOnlyCardsInARunningSprintAreShownAndSprintsEndingSoonestComeFirst() throws {
        let long = try sprint(7, name: "Sprint 7", endsIn: 10)
        let short = try sprint(9, name: "Sprint 9", endsIn: 2)
        let tasks = [
            try task("a", sprint: 7),
            try task("b", status: "in_progress", sprint: 9),
            try task("c", priority: "high", sprint: 9),
            try task("finished-sprint", sprint: 3),
            try task("no-sprint"),
        ]
        let buckets = TaskAgenda.bySprint(tasks, activeSprints: [7: long, 9: short])
        XCTAssertEqual(buckets.map(\.sprint.name), ["Sprint 9", "Sprint 7"])
        XCTAssertEqual(buckets.first?.tasks.map(\.uuid), ["b", "c"], "finish what is started before starting more")
        XCTAssertEqual(buckets.flatMap(\.tasks).count, 3, "cards outside a running sprint stay out")
    }

    // MARK: Decoding

    /// `/my-tasks` joins the project in flat; the sprint list counts completions live.
    func testMyTasksCarriesItsProjectFlatAndSprintsKeepTheirNumericId() throws {
        let json = """
        {"uuid": "t1", "title": "Replace filter", "sprint_id": "9", "project_uuid": "p9",
         "project_name": "DBS service desk", "board_name": "Service", "column_name": "Doing"}
        """
        let card = try JSONDecoder.opsAPI().decode(KanbanTask.self, from: Data(json.utf8))
        XCTAssertEqual(card.sprintId, 9)
        XCTAssertEqual(card.projectUuid, "p9", "the sprint lookup is per project")
        XCTAssertEqual(card.projectName, "DBS service desk")
        XCTAssertEqual(card.columnName, "Doing")

        let running = try sprint(9, name: "Sprint 9", endsIn: 3)
        XCTAssertEqual(running.numericId, 9, "tasks point at sprints by number, not uuid")
        XCTAssertEqual(running.status, .active)
        XCTAssertEqual(running.completedTaskCount, 2)
    }
}
