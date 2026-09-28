package uk.co.workstation.wslcrm.features.projects

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.Endpoint
import uk.co.workstation.wslcrm.core.networking.Envelope
import uk.co.workstation.wslcrm.core.networking.LossyList
import uk.co.workstation.wslcrm.core.networking.Page
import uk.co.workstation.wslcrm.core.networking.QueryBuilder
import kotlin.coroutines.cancellation.CancellationException

/**
 * Projects, boards, tasks and sprints — `/api/v2/kanban` (mirrors KanbanAPI.swift). This module
 * pages with camelCase `perPage`, in the query and the meta.
 */
class KanbanAPI(private val client: APIClient) {

    suspend fun myTasks(page: Int = 1, perPage: Int = 50): Page<KanbanTask> {
        val query = QueryBuilder().apply { add("page", page); add("perPage", perPage) }.items
        val envelope = client.send(Endpoint.get("$BASE/my-tasks", query), Envelope.Kanban.decoder(LossyList(KanbanTask)))
        return Page(envelope.data, envelope.meta?.page ?: page, envelope.meta?.perPage ?: perPage,
            envelope.meta?.total ?: envelope.data.size)
    }

    suspend fun sprints(projectUuid: String, status: KanbanSprintStatus? = null): List<KanbanSprint> {
        val query = QueryBuilder().apply { add("status", status?.wire) }.items
        return client.send(Endpoint.get("$BASE/projects/$projectUuid/sprints", query),
            Envelope.Kanban.decoder(LossyList(KanbanSprint))).data
    }

    /**
     * The running sprints behind these cards, keyed by the numeric id tasks carry as `sprint_id`.
     * `/my-tasks` says which sprint a card is in but not whether that sprint is running, so this
     * asks each project once. A project that refuses (not a member any more) contributes nothing:
     * the cards still show, only without a sprint.
     */
    suspend fun activeSprints(tasks: List<KanbanTask>): Map<Int, KanbanSprint> = coroutineScope {
        tasks.filter { it.sprintId != null }.mapNotNull { it.projectUuid }.toSet()
            .map { project ->
                async {
                    try {
                        sprints(project, KanbanSprintStatus.ACTIVE)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        emptyList()
                    }
                }
            }
            .awaitAll()
            .flatten()
            .filter { it.status == KanbanSprintStatus.ACTIVE }
            .mapNotNull { sprint -> sprint.numericId?.let { it to sprint } }
            .toMap()
    }

    companion object {
        const val BASE = "/api/v2/kanban"
    }
}
