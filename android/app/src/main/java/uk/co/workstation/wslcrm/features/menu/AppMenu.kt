package uk.co.workstation.wslcrm.features.menu

import uk.co.workstation.wslcrm.core.auth.MenuResponse

/**
 * The web dashboard's sidebar, exactly as the server sends it (`GET /api/v2/user/menu`): the same
 * items, groups and order for the same person in the same workspace. The server has already applied
 * the workspace's modules and the person's permissions. Mirrors `Features/Menu/AppMenu.swift`.
 */
data class AppMenu(val sections: List<Section>, val secondary: List<Item>) {
    data class Item(val key: String, val name: String, val icon: String?, val path: String?)

    /** [key] is null for the items the web shows above its groups (Dashboard, Apps, My Tasks, …). */
    data class Section(val key: String?, val title: String?, val items: List<Item>)

    val isEmpty: Boolean get() = sections.isEmpty() && secondary.isEmpty()

    /** Sections narrowed to a search: a group whose name matches keeps all its items. */
    fun filtered(query: String): List<Section> {
        val q = query.trim()
        if (q.isEmpty()) return sections
        return sections.mapNotNull { section ->
            val groupMatches = section.title?.contains(q, ignoreCase = true) == true
            val items = if (groupMatches) section.items else section.items.filter { it.name.contains(q, ignoreCase = true) }
            if (items.isEmpty()) null else section.copy(items = items)
        }
    }

    /** The web page of a menu item, by key — for the tabs that are web pages. */
    fun route(key: String): WebPageRoute? {
        val item = sections.asSequence().flatMap { it.items }.firstOrNull { it.key == key } ?: return null
        val path = item.path?.takeIf { it.startsWith("/") } ?: return null
        return WebPageRoute(item.name, path)
    }

    fun has(key: String): Boolean = sections.any { section -> section.items.any { it.key == key } }

    companion object {
        val EMPTY = AppMenu(emptyList(), emptyList())

        /** The web's AI chat ("AI Navigator", `/dashboard/chat`) and project management. */
        const val AI_CHAT_KEY = "chat"
        const val PROJECTS_KEY = "projects"

        fun from(response: MenuResponse): AppMenu {
            // Older servers send only `menu`; it is the same list, Settings included.
            val main = response.mainMenu.ifEmpty { response.menu.filter { it.key != "settings" } }
            val secondary = if (response.mainMenu.isEmpty()) response.menu.filter { it.key == "settings" } else response.secondaryMenu

            val top = mutableListOf<Item>()
            val grouped = linkedMapOf<String, MutableList<Item>>()
            for (entry in main) {
                val group = entry.group
                if (group.isNullOrEmpty()) top += item(entry) else grouped.getOrPut(group) { mutableListOf() } += item(entry)
            }
            val sections = mutableListOf<Section>()
            if (top.isNotEmpty()) sections += Section(null, null, top)
            val placed = mutableSetOf<String>()
            for (group in response.groups) {
                if (!placed.add(group.key)) continue
                val items = grouped[group.key] ?: continue
                sections += Section(group.key, title(group.name, group.key), items)
            }
            // A group the server didn't describe still shows, after the others, in first-seen order.
            for ((key, items) in grouped) if (key !in placed) sections += Section(key, title(null, key), items)
            return AppMenu(sections, secondary.map(::item))
        }

        private fun item(entry: MenuResponse.MenuItem): Item {
            val name = entry.name?.trim().takeUnless { it.isNullOrEmpty() } ?: entry.key
            return Item(entry.key, name, entry.icon, entry.path)
        }

        private fun title(name: String?, key: String): String {
            if (!name.isNullOrEmpty()) return name
            // `plugin:property_pa` -> "Property pa"
            val words = key.substringAfterLast(':').replace('_', ' ')
            return words.replaceFirstChar { it.uppercase() }
        }
    }
}

/** Where tapping a menu item goes: the app's own Shop screens, or the web page inside the app. */
sealed interface MenuDestination {
    data object Shop : MenuDestination
    data class Web(val route: WebPageRoute) : MenuDestination

    companion object {
        /** null when the item has neither a screen nor a page (nothing to open). */
        fun of(item: AppMenu.Item): MenuDestination? {
            if (item.key == "shop") return Shop
            val path = item.path?.takeIf { it.startsWith("/") } ?: return null
            return Web(WebPageRoute(item.name, path))
        }
    }
}
