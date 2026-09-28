package uk.co.workstation.wslcrm.features.projects

import uk.co.workstation.wslcrm.core.networking.CalendarDay

/**
 * How a person's assigned cards turn into a day's work (mirrors TaskAgenda.swift). Kept apart from
 * any screen so My Work, My tasks and the tests all answer "what should I be doing today" the same
 * way. `today` is passed in, in the person's own zone, never read from the clock here.
 */
object TaskAgenda {
    data class Bucket(val id: String, val title: String, val tasks: List<KanbanTask>)

    data class SprintBucket(val sprint: KanbanSprint, val tasks: List<KanbanTask>)

    /**
     * Cards that are still somebody's job. The server already drops finished ones from
     * `/my-tasks`; this keeps a card finished on this phone from lingering until the next load.
     */
    fun open(tasks: List<KanbanTask>): List<KanbanTask> = tasks.filterNot { it.status.isFinished }

    private val dueFirst = compareBy<KanbanTask, CalendarDay?>(nullsLast()) { it.dueDate }

    /** Overdue, Today, This week, Later — by due date, nearest first. */
    fun byDueDate(tasks: List<KanbanTask>, today: CalendarDay): List<Bucket> {
        val weekEnd = CalendarDay.of(today.toLocalDate().plusDays(7))
        fun bucket(task: KanbanTask): Int {
            val due = task.dueDate ?: return 3
            return when {
                due < today -> 0
                due == today -> 1
                due <= weekEnd -> 2
                else -> 3
            }
        }
        val ids = listOf("overdue", "today", "week", "later")
        val titles = listOf("Overdue", "Today", "This week", "Later")
        val open = open(tasks)
        return (0..3).mapNotNull { index ->
            val group = open.filter { bucket(it) == index }.sortedWith(dueFirst)
            if (group.isEmpty()) null else Bucket(ids[index], titles[index], group)
        }
    }

    /**
     * What to work on today: anything overdue, anything due today, and anything already started.
     * Overdue comes first because it is already late; then today's deadlines; then work in flight
     * without one. Within each, the more urgent priority wins, then the nearer date.
     */
    fun today(tasks: List<KanbanTask>, today: CalendarDay): List<KanbanTask> {
        fun rank(task: KanbanTask): Int? {
            val due = task.dueDate
            return when {
                due != null && due == today -> 1
                due != null && due < today -> 0
                task.status == KanbanTaskStatus.IN_PROGRESS -> 2
                else -> null
            }
        }
        return open(tasks)
            .mapNotNull { task -> rank(task)?.let { task to it } }
            .sortedWith(compareBy<Pair<KanbanTask, Int>> { it.second }
                .thenBy { it.first.priority.urgency }
                .thenBy(nullsLast()) { it.first.dueDate })
            .map { it.first }
    }

    /**
     * The cards in each running sprint, sprint ending soonest first. Within a sprint, work already
     * started leads, because finishing beats starting when the sprint has an end date.
     */
    fun bySprint(tasks: List<KanbanTask>, activeSprints: Map<Int, KanbanSprint>): List<SprintBucket> =
        open(tasks)
            .filter { task -> task.sprintId?.let { it in activeSprints } == true }
            .groupBy { it.sprintId!! }
            .mapNotNull { (id, cards) ->
                activeSprints[id]?.let { sprint ->
                    SprintBucket(sprint, cards.sortedWith(
                        compareBy<KanbanTask> { if (it.status == KanbanTaskStatus.IN_PROGRESS) 0 else 1 }
                            .thenBy { it.priority.urgency }
                            .then(dueFirst),
                    ))
                }
            }
            .sortedWith(compareBy<SprintBucket, CalendarDay?>(nullsLast()) { it.sprint.endDate }.thenBy { it.sprint.name })
}
