package uk.co.workstation.wslcrm.features.projects

import uk.co.workstation.wslcrm.core.networking.CalendarDay
import uk.co.workstation.wslcrm.core.networking.JsonDecodable
import uk.co.workstation.wslcrm.core.networking.decodeObject
import java.time.Instant

// Projects, boards, tasks and sprints, served by OPSAPI's /api/v2/kanban routes (mirrors
// KanbanModels.swift). Only what My tasks needs so far; the rest arrives with the screens.

enum class KanbanTaskStatus(val wire: String) {
    OPEN("open"), IN_PROGRESS("in_progress"), BLOCKED("blocked"), REVIEW("review"),
    COMPLETED("completed"), CANCELLED("cancelled"), UNKNOWN("unknown");

    val isFinished: Boolean get() = this == COMPLETED || this == CANCELLED

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.wire == raw } ?: if (raw == null) OPEN else UNKNOWN
    }
}

enum class KanbanTaskPriority(val wire: String) {
    CRITICAL("critical"), HIGH("high"), MEDIUM("medium"), LOW("low"), NONE("none"), UNKNOWN("unknown");

    /** Lower is more urgent; the order the server sorts `/my-tasks` by. */
    val urgency: Int
        get() = when (this) {
            CRITICAL -> 0
            HIGH -> 1
            MEDIUM -> 2
            LOW -> 3
            NONE, UNKNOWN -> 4
        }

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.wire == raw } ?: if (raw == null) NONE else UNKNOWN
    }
}

data class KanbanTask(
    val uuid: String,
    val numericId: Int? = null,
    val boardId: Int? = null,
    val columnId: Int? = null,
    /** Tasks point at their sprint by number, never by uuid. */
    val sprintId: Int? = null,
    val taskNumber: Int? = null,
    val title: String = "Untitled",
    val status: KanbanTaskStatus = KanbanTaskStatus.OPEN,
    val priority: KanbanTaskPriority = KanbanTaskPriority.NONE,
    /**
     * `due_date` is a date column. Kept as a [CalendarDay] so a card due today is due today in
     * every time zone — read as midnight UTC it would be "overdue" from 1am in a British summer.
     */
    val dueDate: CalendarDay? = null,
    val commentCount: Int = 0,
    val updatedAt: Instant? = null,
    val projectSlug: String? = null,
    /** `/my-tasks` joins these in flat rather than nesting a project. */
    val projectUuid: String? = null,
    val projectName: String? = null,
    val boardName: String? = null,
    val columnName: String? = null,
) {
    /** What people say out loud: the board-sequential number, not the uuid. */
    val reference: String
        get() {
            val number = taskNumber ?: return uuid.take(8)
            val key = projectSlug?.uppercase()
            return if (!key.isNullOrEmpty()) "$key-$number" else "#$number"
        }

    fun isOverdue(today: CalendarDay): Boolean = !status.isFinished && dueDate != null && dueDate < today

    companion object : JsonDecodable<KanbanTask> {
        override fun decode(json: kotlinx.serialization.json.JsonElement): KanbanTask = decodeObject(json) {
            val project = obj("project")
            KanbanTask(
                uuid = requireString("uuid"),
                numericId = flexibleInt("id"),
                boardId = flexibleInt("boardId"),
                columnId = flexibleInt("columnId"),
                sprintId = flexibleInt("sprintId"),
                taskNumber = flexibleInt("taskNumber"),
                title = string("title") ?: "Untitled",
                status = KanbanTaskStatus.of(string("status")),
                priority = KanbanTaskPriority.of(string("priority")),
                dueDate = day("dueDate"),
                commentCount = flexibleInt("commentCount") ?: 0,
                updatedAt = date("updatedAt"),
                projectSlug = project?.string("slug"),
                projectUuid = string("projectUuid") ?: project?.string("uuid"),
                projectName = string("projectName") ?: project?.string("name"),
                boardName = string("boardName"),
                columnName = string("columnName"),
            )
        }
    }
}

enum class KanbanSprintStatus(val wire: String) {
    PLANNED("planned"), PLANNING("planning"), ACTIVE("active"), COMPLETED("completed"),
    CANCELLED("cancelled"), UNKNOWN("unknown");

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.wire == raw } ?: if (raw == null) PLANNED else UNKNOWN
    }
}

data class KanbanSprint(
    val uuid: String,
    /** What tasks carry as `sprint_id`. */
    val numericId: Int? = null,
    val name: String = "Sprint",
    val goal: String? = null,
    val status: KanbanSprintStatus = KanbanSprintStatus.PLANNED,
    val startDate: CalendarDay? = null,
    val endDate: CalendarDay? = null,
    val totalPoints: Int = 0,
    val completedPoints: Int = 0,
    val taskCount: Int = 0,
    val completedTaskCount: Int = 0,
) {
    val progress: Double
        get() = when {
            totalPoints > 0 -> completedPoints.toDouble() / totalPoints
            taskCount > 0 -> completedTaskCount.toDouble() / taskCount
            else -> 0.0
        }

    companion object : JsonDecodable<KanbanSprint> {
        override fun decode(json: kotlinx.serialization.json.JsonElement): KanbanSprint = decodeObject(json) {
            KanbanSprint(
                uuid = requireString("uuid"),
                numericId = flexibleInt("id"),
                name = string("name") ?: "Sprint",
                goal = string("goal"),
                status = KanbanSprintStatus.of(string("status")),
                startDate = day("startDate"),
                endDate = day("endDate"),
                totalPoints = flexibleInt("totalPoints") ?: 0,
                completedPoints = flexibleInt("completedPoints") ?: 0,
                taskCount = flexibleInt("taskCount") ?: 0,
                // The list query counts live into `completed_count`; the stored column lags behind it.
                completedTaskCount = flexibleInt("completedCount") ?: flexibleInt("completedTaskCount") ?: 0,
            )
        }
    }
}
