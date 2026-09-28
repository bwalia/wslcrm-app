package uk.co.workstation.wslcrm.features.projects

import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uk.co.workstation.wslcrm.core.auth.AuthTokens
import uk.co.workstation.wslcrm.core.auth.InMemoryTokenStore
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.CalendarDay
import uk.co.workstation.wslcrm.core.networking.OpsJson

/**
 * What "today" and "this sprint" mean for someone's assigned cards (mirrors TaskAgendaTests.swift).
 * A card that is late never hides behind one that merely matters.
 */
class TaskAgendaTest {
    private val today = CalendarDay(2026, 9, 28)
    private fun day(offset: Long) = CalendarDay.of(today.toLocalDate().plusDays(offset))

    private fun task(
        uuid: String, status: String = "open", priority: String = "none",
        due: Long? = null, sprint: Int? = null, project: String = "p1",
    ): KanbanTask {
        val fields = mutableListOf("\"uuid\": \"$uuid\"", "\"title\": \"$uuid\"", "\"status\": \"$status\"",
            "\"priority\": \"$priority\"", "\"project_uuid\": \"$project\"")
        due?.let { fields += "\"due_date\": \"${day(it)}\"" }
        sprint?.let { fields += "\"sprint_id\": $it" }
        return KanbanTask.decode(OpsJson.parse("{${fields.joinToString(",")}}"))
    }

    private fun sprint(id: Int, name: String, endsIn: Long, status: String = "active") = KanbanSprint.decode(
        OpsJson.parse("""{"uuid": "s$id", "id": $id, "name": "$name", "status": "$status",
            "end_date": "${day(endsIn)}", "task_count": 6, "completed_count": 2}"""),
    )

    // MARK: Today

    @Test fun todayIsWhatIsLateThenWhatIsDueThenWhatIsAlreadyStarted() {
        val tasks = listOf(
            task("started", status = "in_progress", due = 5),
            task("due-today", due = 0),
            task("late", due = -2),
            task("next-week", due = 6),
            task("no-date"),
        )
        assertEquals("cards due later and not started are tomorrow's problem",
            listOf("late", "due-today", "started"), TaskAgenda.today(tasks, today).map { it.uuid })
    }

    @Test fun withinTodayTheMoreUrgentCardLeads() {
        val tasks = listOf(task("low", priority = "low", due = 0), task("critical", priority = "critical", due = 0))
        assertEquals(listOf("critical", "low"), TaskAgenda.today(tasks, today).map { it.uuid })
    }

    @Test fun aFinishedCardLeavesTodayEvenBeforeTheNextLoad() {
        val tasks = listOf(task("done", status = "completed", due = 0), task("dropped", status = "cancelled", due = -1))
        assertTrue(TaskAgenda.today(tasks, today).isEmpty())
    }

    /** `due_date` is a date column: "2026-09-28" is the 28th wherever the phone is. */
    @Test fun aDateOnlyDeadlineIsKeptAsTheDayItNames() {
        val card = KanbanTask.decode(OpsJson.parse("""{"uuid": "t", "due_date": "2026-09-28"}"""))
        assertEquals(today, card.dueDate)
        assertEquals(false, card.isOverdue(today))
        assertEquals(true, card.isOverdue(day(1)))
    }

    @Test fun byDueDateStillGroupsEverything() {
        val tasks = listOf(task("late", due = -1), task("today", due = 0), task("soon", due = 3), task("someday"))
        val buckets = TaskAgenda.byDueDate(tasks, today)
        assertEquals(listOf("Overdue", "Today", "This week", "Later"), buckets.map { it.title })
        assertEquals(4, buckets.sumOf { it.tasks.size })
    }

    // MARK: Sprint

    @Test fun onlyCardsInARunningSprintAreShownAndSprintsEndingSoonestComeFirst() {
        val long = sprint(7, "Sprint 7", endsIn = 10)
        val short = sprint(9, "Sprint 9", endsIn = 2)
        val tasks = listOf(
            task("a", sprint = 7),
            task("b", status = "in_progress", sprint = 9),
            task("c", priority = "high", sprint = 9),
            task("finished-sprint", sprint = 3),
            task("no-sprint"),
        )
        val buckets = TaskAgenda.bySprint(tasks, mapOf(7 to long, 9 to short))
        assertEquals(listOf("Sprint 9", "Sprint 7"), buckets.map { it.sprint.name })
        assertEquals("finish what is started before starting more", listOf("b", "c"), buckets.first().tasks.map { it.uuid })
        assertEquals("cards outside a running sprint stay out", 3, buckets.sumOf { it.tasks.size })
    }

    // MARK: Decoding

    /** `/my-tasks` joins the project in flat; the sprint list counts completions live. */
    @Test fun myTasksCarriesItsProjectFlatAndSprintsKeepTheirNumericId() {
        val card = KanbanTask.decode(OpsJson.parse("""{"uuid": "t1", "title": "Replace filter", "sprint_id": "9",
            "project_uuid": "p9", "project_name": "DBS service desk", "board_name": "Service", "column_name": "Doing"}"""))
        assertEquals(9, card.sprintId)
        assertEquals("the sprint lookup is per project", "p9", card.projectUuid)
        assertEquals("DBS service desk", card.projectName)
        assertEquals("Doing", card.columnName)

        val running = sprint(9, "Sprint 9", endsIn = 3)
        assertEquals("tasks point at sprints by number, not uuid", 9, running.numericId)
        assertEquals(KanbanSprintStatus.ACTIVE, running.status)
        assertEquals(2, running.completedTaskCount)
    }
}

/** The per-project sprint lookup, against a real HTTP round trip. */
class ActiveSprintLookupTest {
    private lateinit var server: MockWebServer
    private val requested = mutableListOf<String>()

    @Before fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.path ?: ""
                synchronized(requested) { requested += path }
                return when {
                    path.startsWith("/api/v2/kanban/projects/p1/sprints") -> MockResponse().setBody(
                        """{"success": true, "data": [
                            {"uuid": "s1", "id": 1, "name": "Week 38", "status": "active"},
                            {"uuid": "s0", "id": 0, "name": "Week 37", "status": "completed"}]}""",
                    )
                    else -> MockResponse().setResponseCode(403).setBody("""{"success": false, "error": "Access denied"}""")
                }
            }
        }
        server.start()
    }

    @After fun tearDown() = server.shutdown()

    @Test fun asksEachProjectOnceAndARefusalOnlyCostsThatProjectsSprint() = runTest {
        // Signed in (a JWT that expires in 2100, so no proactive refresh) and in a workspace.
        val client = APIClient(server.url("/").toString().trimEnd('/'),
            InMemoryTokenStore(AuthTokens("eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjQxMDI0NDQ4MDB9.stub", "refresh")))
        client.setNamespace("ns-1")
        val api = KanbanAPI(client)
        fun card(uuid: String, project: String, sprint: Int?) = KanbanTask(uuid, sprintId = sprint, projectUuid = project)
        val sprints = api.activeSprints(listOf(
            card("a", "p1", 1), card("b", "p1", 1),
            card("c", "p2", 5),
            card("d", "p3", null),
        ))
        assertEquals("only running sprints, keyed by the number tasks carry", setOf(1), sprints.keys)
        val sprintCalls = requested.filter { it.contains("/sprints") }
        assertEquals("p1 and p2 once each; p3 has no sprinted cards", 2, sprintCalls.size)
        assertTrue(sprintCalls.all { it.contains("status=active") })
    }
}
