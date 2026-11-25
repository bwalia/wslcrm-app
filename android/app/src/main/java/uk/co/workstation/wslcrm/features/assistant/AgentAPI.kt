package uk.co.workstation.wslcrm.features.assistant

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import uk.co.workstation.wslcrm.app.AppContainer
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.Endpoint
import uk.co.workstation.wslcrm.core.networking.HttpMethod
import uk.co.workstation.wslcrm.core.networking.JsonDecodable
import uk.co.workstation.wslcrm.core.networking.QueryItem
import uk.co.workstation.wslcrm.core.networking.decodeObject
import java.time.LocalDate

/**
 * The AI agent (`routes/chat-agent.lua`): the conversation lives on the server and each turn runs there in the
 * background, so leaving the screen never stops it. Mirrors the agent half of `ChatAPI.swift`.
 *
 *   GET    /api/chat/agent/conversation?path=   that page's conversation + run status
 *   POST   /api/chat/agent                      {message, path, local_date} → starts a run
 *   POST   /api/chat/agent/confirm              {approve, path} runs/cancels a pending delete
 *   DELETE /api/chat/agent/conversation?path=   "New conversation"
 */
class AgentAPI(private val client: APIClient) {
    suspend fun conversation(path: String? = null): AgentConversation =
        client.send(Endpoint.get("$BASE/conversation", pathQuery(path)), AgentConversation)

    suspend fun send(message: String, path: String? = null, today: LocalDate = LocalDate.now()): AgentConversation =
        client.send(Endpoint.post(BASE, AgentMessageBody(message, path, today.toString())), AgentConversation)

    suspend fun confirm(approve: Boolean, path: String? = null, today: LocalDate = LocalDate.now()): AgentConversation =
        client.send(Endpoint.post("$BASE/confirm", AgentConfirmBody(approve, path, today.toString())), AgentConversation)

    suspend fun reset(path: String? = null) {
        client.sendDiscardingBody(Endpoint(HttpMethod.DELETE, "$BASE/conversation", pathQuery(path)))
    }

    private fun pathQuery(path: String?) = path?.trim()?.takeIf { it.isNotEmpty() }?.let { listOf(QueryItem("path", it)) }.orEmpty()

    companion object {
        const val BASE = "/api/chat/agent"
    }
}

val AppContainer.agent: AgentAPI get() = service { AgentAPI(client) }

@Serializable
data class AgentMessageBody(val message: String, val path: String? = null, val localDate: String)

@Serializable
data class AgentConfirmBody(val approve: Boolean, val path: String? = null, val localDate: String)

/** One step the agent took: `call_api` with a label such as "GET /api/v2/crm/leads", or a named tool. */
data class AgentAction(val name: String, val label: String? = null, val method: String? = null, val error: String? = null) {
    /** "PUT /api/v2/kanban/tasks/<uuid>/move" → "PUT kanban/tasks/…/move". */
    val displayLabel: String
        get() {
            var text = label ?: name.replace('_', ' ').replaceFirstChar { it.uppercase() }
            for (prefix in listOf(" /api/v2/", " /api/")) text = text.replace(prefix, " ")
            return text.replace(Regex("[0-9a-fA-F]{8}-[0-9a-fA-F-]{20,}"), "…")
        }

    companion object : JsonDecodable<AgentAction> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val error = flexibleString("error")?.trim()?.takeIf { it.isNotEmpty() }
                ?: obj("error")?.string("message")
            AgentAction(flexibleString("name") ?: "action", flexibleString("label")?.trim()?.takeIf { it.isNotEmpty() },
                flexibleString("method"), error)
        }
    }
}

data class AgentTurn(val role: String, val content: String, val actions: List<AgentAction> = emptyList()) {
    val isUser: Boolean get() = role == "user"
    val visibleActions: List<AgentAction> get() = actions.filter { it.name != "ask_user" }

    companion object : JsonDecodable<AgentTurn> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            AgentTurn(flexibleString("role") ?: "assistant", flexibleString("content").orEmpty(),
                lossyList("actions", AgentAction))
        }
    }
}

data class AgentConversation(
    val runUuid: String? = null,
    val status: Status,
    val turns: List<AgentTurn>,
    val scopeTitle: String? = null,
    val suggestions: List<String> = emptyList(),
    /** A delete (or another guarded action) waiting for the person to confirm. */
    val pendingSummary: String? = null,
    /** The finished run created or changed data. */
    val changed: Boolean = false,
) {
    enum class Status { IDLE, RUNNING, DONE, ERROR }

    val isRunning: Boolean get() = status == Status.RUNNING
    val lastRequest: String? get() = turns.lastOrNull { it.isUser }?.content?.trim()?.takeIf { it.isNotEmpty() }

    companion object : JsonDecodable<AgentConversation> {
        override fun decode(json: JsonElement) = decodeObject(json) {
            val status = when (flexibleString("status")) {
                "running" -> Status.RUNNING
                "done" -> Status.DONE
                "error" -> Status.ERROR
                else -> Status.IDLE
            }
            val scope = obj("scope")
            AgentConversation(
                runUuid = flexibleString("runUuid"),
                status = status,
                turns = lossyList("turns", AgentTurn),
                scopeTitle = scope?.string("title"),
                suggestions = scope?.stringList("suggestions").orEmpty(),
                pendingSummary = obj("pending")?.string("summary")?.trim()?.takeIf { it.isNotEmpty() },
                changed = flexibleBool("changed") ?: false,
            )
        }
    }
}
