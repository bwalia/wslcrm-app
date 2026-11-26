package uk.co.workstation.wslcrm.features.assistant

import uk.co.workstation.wslcrm.features.menu.AppMenu
import uk.co.workstation.wslcrm.features.menu.MenuDestination

/**
 * Reads what someone typed into the command box (Home, or the assistant) and decides whether it is a place to go —
 * "open shop", "leads", "show me my tasks" — which opens at once, or a job for the AI agent. Pure, so typing stays
 * instant and the rules are unit-tested. Mirrors `Features/Home/CommandRouter.swift`.
 */
object CommandRouter {
    data class Place(val key: String, val name: String, val icon: String?, val aliases: List<String> = emptyList())

    sealed interface Decision {
        data class Open(val place: Place) : Decision
        data class Ask(val request: String) : Decision
    }

    private val openVerbs = listOf("take me to", "switch to", "show me", "go to", "open up", "open", "show", "launch",
        "view", "see", "find", "my")
    private val fillers = listOf("page", "screen", "app", "tab", "area", "section", "please", "list", "dashboard")

    /** Only an exact place (after the "open"/"show me" words) navigates; anything more is a request for the agent. */
    fun decide(text: String, places: List<Place>): Decision? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        val wanted = placePhrase(trimmed)
        val place = if (wanted.isEmpty()) null else places.firstOrNull { matches(it, wanted) }
        return place?.let { Decision.Open(it) } ?: Decision.Ask(trimmed)
    }

    /** Places whose name or alias contains what's typed, best first ("Jump to"). */
    fun search(text: String, places: List<Place>, limit: Int = 6): List<Place> {
        val query = normalise(placePhrase(text))
        if (query.length < 2) return emptyList()
        return places.mapNotNull { place ->
            val names = (listOf(place.name) + place.aliases).map(::normalise)
            val rank = when {
                query in names -> 0
                names.any { it.startsWith(query) } -> 1
                names.any { name -> name.split(' ').any { it.startsWith(query) } } -> 2
                names.any { it.contains(query) } -> 3
                else -> null
            }
            rank?.let { place to it }
        }.sortedBy { it.second }.map { it.first }.distinctBy { it.key }.take(limit)
    }

    /** "Open the shop page please" → "shop". */
    fun placePhrase(text: String): String {
        var phrase = normalise(text)
        var changed = true
        while (changed) {
            changed = false
            for (verb in openVerbs) if (phrase.startsWith("$verb ")) { phrase = phrase.removePrefix("$verb "); changed = true }
            for (article in listOf("the ", "a ", "all ", "our ")) if (phrase.startsWith(article)) {
                phrase = phrase.removePrefix(article); changed = true
            }
            for (filler in fillers) if (phrase.endsWith(" $filler")) { phrase = phrase.removeSuffix(" $filler"); changed = true }
        }
        return phrase
    }

    fun normalise(text: String): String =
        text.lowercase().replace(Regex("[^\\p{L}\\p{N}\\s]"), " ").split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

    private fun matches(place: Place, phrase: String): Boolean =
        (listOf(place.name) + place.aliases).map(::normalise).any { it == phrase || singular(it) == singular(phrase) }

    private fun singular(word: String) = if (word.endsWith("s") && word.length > 3) word.dropLast(1) else word

    /** Everyday words for the app's areas, by menu key. */
    val aliases: Map<String, List<String>> = mapOf(
        "shop" to listOf("store", "shop admin", "orders and quotes"),
        "orders" to listOf("sales orders"),
        "products" to listOf("stock", "inventory", "catalogue", "catalog"),
        "crm_leads" to listOf("lead", "enquiries", "prospects"),
        "customers" to listOf("clients", "contacts"),
        "my_tasks" to listOf("tasks", "todo", "to do", "to dos", "todos"),
        "projects" to listOf("boards", "kanban"),
        "invoices" to listOf("bills", "billing"),
        "timesheets" to listOf("time", "hours", "time sheets"),
        "field_service_jobs" to listOf("jobs", "field service", "engineers"),
        "field_service_requests" to listOf("requests", "service requests", "tickets"),
        "purchase_orders" to listOf("pos", "purchase orders"),
        "chat" to listOf("chat", "messages", "ai navigator", "assistant"),
    )

    /** Every page in the person's menu that the app can open, as places the command box can open. An item with
     * nowhere to go (no screen, no page) isn't offered: tapping it did nothing. */
    fun places(menu: AppMenu): List<Place> =
        menu.sections.flatMap { it.items }.filter { it.key !in setOf("dashboard", "apps") }
            .filter { it.key == AppMenu.AI_CHAT_KEY || MenuDestination.of(it) != null }
            .map { Place(it.key, it.name, it.icon, aliases[it.key].orEmpty()) }
            .distinctBy { it.key }

    /** Up to five things to ask, led by what needs the person today. */
    fun suggestions(signalIds: List<String>): List<String> {
        val out = signalIds.mapNotNull { prompts[it] }.toMutableList()
        for (general in listOf("What should I focus on today?", "Summarise this week's sales", "Create a task for me")) {
            if (general !in out) out += general
        }
        return out.take(5)
    }

    val prompts: Map<String, String> = mapOf(
        "shop.payment" to "Which orders are still waiting for payment?",
        "shop.fulfil" to "Which paid orders do I need to send?",
        "shop.quotes" to "Which open quotes should I chase first?",
        "shop.stock" to "Which low-stock products should I reorder?",
    )
}

/** The screens an agent's actions touched, so a reply can offer "Open Leads" next to what it did. */
object AgentActionScreens {
    private val rules = listOf(
        "shop/admin" to "shop",
        "crm/leads" to "crm_leads", "/leads" to "crm_leads", "lead" to "crm_leads",
        "crm/" to "crm",
        "customers" to "customers",
        "purchase-orders" to "purchase_orders", "purchase_orders" to "purchase_orders",
        "invoices" to "invoices", "invoice" to "invoices",
        "timesheets" to "timesheets", "timesheet" to "timesheets",
        "kanban/tasks" to "my_tasks", "my_tasks" to "my_tasks",
        "kanban/projects" to "projects", "project" to "projects",
        "service-requests" to "field_service_requests",
        "field-service/jobs" to "field_service_jobs",
        "products" to "products", "orders" to "orders",
    )

    fun keys(actions: List<AgentAction>, limit: Int = 3): List<String> {
        val out = mutableListOf<String>()
        for (action in actions) {
            if (action.error != null || action.name == "ask_user") continue
            val haystack = "${action.label.orEmpty()} ${action.name}".lowercase()
            val key = rules.firstOrNull { haystack.contains(it.first) }?.second ?: continue
            if (key !in out) out += key
            if (out.size == limit) break
        }
        return out
    }
}
