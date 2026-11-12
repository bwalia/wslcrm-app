package uk.co.workstation.wslcrm.features.menu

import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.workstation.wslcrm.core.auth.CurrentUser
import uk.co.workstation.wslcrm.core.auth.MenuResponse
import uk.co.workstation.wslcrm.core.auth.Workspace
import uk.co.workstation.wslcrm.core.networking.OpsJson

/**
 * The Menu tab mirrors the web sidebar, and modules without a screen open the web page signed in.
 * Same fixture as MenuTests.swift: the real `GET /api/v2/user/menu` for a platform admin in a
 * workspace with every module (`../WSLCRMTests/Fixtures/user_menu_root.json`).
 */
class AppMenuTest {
    private fun rootResponse(): MenuResponse {
        val bytes = requireNotNull(javaClass.classLoader?.getResource("user_menu_root.json")) { "Missing fixture" }.readBytes()
        return OpsJson.decode(MenuResponse, bytes)
    }

    private fun rootMenu() = AppMenu.from(rootResponse())

    // Same menu as the web

    @Test fun rootGetsEveryItemTheWebSidebarShows() {
        val response = rootResponse()
        val keys = rootMenu().sections.flatMap { s -> s.items.map { it.key } }
        assertEquals(91, keys.size)
        val expected = response.mainMenu.filter { it.group == null }.map { it.key } +
            response.groups.flatMap { g -> response.mainMenu.filter { it.group == g.key }.map { it.key } }
        assertEquals("same items, same order", expected, keys)
        for (key in listOf("chat", "forms", "cms", "accounting", "users", "roles", "vault", "billing", "tax", "crm", "invoices")) {
            assertTrue("$key is on the web, so it's in the app", key in keys)
        }
        assertEquals(listOf("settings"), rootMenu().secondary.map { it.key })
    }

    @Test fun groupsKeepTheWebNamesAndOrder() {
        val menu = rootMenu()
        assertNull("Dashboard, Apps, My Tasks… sit above the groups", menu.sections.first().title)
        assertEquals(listOf("dashboard", "apps", "my_tasks", "chat", "ats"), menu.sections.first().items.map { it.key })
        assertEquals("Sales & CRM", menu.sections[1].title)
        assertEquals("developer", menu.sections.last().key)
    }

    @Test fun anOlderServerWithOnlyTheFlatMenuStillWorks() {
        val json = """{"menu":[{"key":"dashboard","name":"Dashboard","path":"/dashboard"},{"key":"crm","name":"CRM","path":"/dashboard/crm"},
            {"key":"settings","name":"Settings","path":"/dashboard/settings"}],"permissions":{},"is_admin":false}"""
        val menu = AppMenu.from(OpsJson.decode(MenuResponse, json.toByteArray()))
        assertEquals(listOf<String?>(null), menu.sections.map { it.key })
        assertEquals(listOf("dashboard", "crm"), menu.sections.single().items.map { it.key })
        assertEquals(listOf("settings"), menu.secondary.map { it.key })
    }

    @Test fun search() {
        val menu = rootMenu()
        assertEquals(menu.sections.size, menu.filtered("").size)
        assertEquals(listOf("ats"), menu.filtered("hiring").flatMap { s -> s.items.map { it.key } })
        assertTrue("a matching group keeps all its items", menu.filtered("Tax").any { it.key == "tax" && it.items.size == 10 })
        assertTrue(menu.filtered("zzz-nothing").isEmpty())
    }

    @Test fun aiChatAndProjectsAreTheWebPages() {
        val menu = rootMenu()
        assertEquals(WebPageRoute("AI Navigator", "/dashboard/chat"), menu.route(AppMenu.AI_CHAT_KEY))
        assertEquals(WebPageRoute("Projects", "/dashboard/projects"), menu.route(AppMenu.PROJECTS_KEY))
        assertNull(menu.route("not-there"))
        assertTrue(menu.has("chat"))
        assertFalse(menu.has("nope"))
    }

    @Test fun whereItemsOpen() {
        fun item(key: String, path: String? = "/dashboard/x") = AppMenu.Item(key, "X", null, path)
        assertEquals(MenuDestination.Shop, MenuDestination.of(item("shop")))
        assertEquals(MenuDestination.Web(WebPageRoute("X", "/dashboard/chat")), MenuDestination.of(item("chat", "/dashboard/chat")))
        assertNull("no page", MenuDestination.of(item("odd", null)))
        assertNull("only dashboard paths", MenuDestination.of(item("odd", "https://elsewhere.example")))
        val unreachable = rootMenu().sections.flatMap { it.items }.filter { MenuDestination.of(it) == null }
        assertEquals("every item root sees opens something", emptyList<AppMenu.Item>(), unreachable)
    }

    // The dashboard next to the API

    @Test fun dashboardAddressFollowsTheAPI() {
        assertEquals("https://int-opsapi-ui.workstation.co.uk", DashboardUrl.forApi("https://int-opsapi.workstation.co.uk"))
        assertEquals("https://opsapi-ui.workstation.co.uk", DashboardUrl.forApi("https://opsapi.workstation.co.uk"))
        assertEquals("http://10.0.2.2:8039", DashboardUrl.forApi("http://10.0.2.2:4011"))
        assertEquals("http://127.0.0.1:8039", DashboardUrl.forApi("http://127.0.0.1:4020"))
        assertNull(DashboardUrl.forApi("https://api.example.com"))
        assertEquals("http://10.0.2.2:8039", DashboardUrl.origin("http://10.0.2.2:8039/dashboard/chat"))
        assertEquals("https://opsapi-ui.workstation.co.uk", DashboardUrl.origin("https://opsapi-ui.workstation.co.uk:443/x"))
    }

    // Signing the page in

    private fun session(firstName: String = "Root") = WebSession(
        dashboard = "https://int-opsapi-ui.workstation.co.uk",
        accessToken = "header.payload.sig",
        user = CurrentUser(uuid = "u-1", email = "root@example.com", firstName = firstName, lastName = "User"),
        workspace = Workspace(uuid = "ns-1", internalId = 2, name = "Workstation", slug = "workstation", isOwner = true),
    )

    @Test fun theBootstrapPageWritesTheSignInOnTheDashboardOnly() {
        val html = session().bootstrapHtml("https://int-opsapi-ui.workstation.co.uk/dashboard/chat")
        assertTrue("origin guard", html.contains("if (window.location.origin !== \"https://int-opsapi-ui.workstation.co.uk\") { return; }"))
        for (key in listOf("auth_token", "auth_user", "auth-storage", "current_namespace", "namespace-storage")) {
            assertTrue(key, html.contains("localStorage.setItem('$key'"))
        }
        assertTrue("in-app mode", html.contains("localStorage.setItem('opsapi-embed', 'app')"))
        assertTrue(html.contains("\"uuid\":\"ns-1\""))
        assertTrue(html.contains("window.location.replace(\"https://int-opsapi-ui.workstation.co.uk/dashboard/chat\")"))
    }

    @Test fun oddCharactersCantCloseTheScript() {
        val html = session("""Ro"ot</script><img src=x>""").bootstrapHtml("https://int-opsapi-ui.workstation.co.uk/x")
        assertFalse("no raw </script> from a value", html.substringBeforeLast("</script>").contains("</script>"))
        assertTrue(html.contains("Ro\\\"ot\\u003c/script>\\u003cimg src=x>"))
        assertEquals("\"a\\u003cb\"", WebSession.json(JsonPrimitive("a<b")))
    }

    // What the page may load

    @Test fun onlyTheDashboardLoadsInsideTheApp() {
        val d = "https://int-opsapi-ui.workstation.co.uk"
        fun decide(url: String, main: Boolean = true) = WebNavigation.decide(url, d, main)
        assertEquals(WebNavigation.ALLOW, decide("$d/dashboard/chat"))
        assertEquals(WebNavigation.SIGN_IN_AGAIN, decide("$d/login"))
        assertEquals(WebNavigation.SIGN_IN_AGAIN, decide("$d/login?next=/x"))
        assertEquals(WebNavigation.ALLOW, decide("$d/login-help"))
        assertEquals(WebNavigation.OPEN_OUTSIDE, decide("https://www.workstation.co.uk/pricing"))
        assertEquals(WebNavigation.OPEN_OUTSIDE, decide("mailto:someone@example.com"))
        assertEquals(WebNavigation.BLOCK, decide("javascript:alert(1)"))
        assertEquals(WebNavigation.ALLOW, decide("about:blank"))
        assertEquals(WebNavigation.ALLOW, decide("https://js.stripe.com/frame", main = false))
        assertEquals(WebNavigation.BLOCK, decide("http://insecure.example/frame", main = false))
        assertEquals(WebNavigation.BLOCK, WebNavigation.decide(null, d, true))
    }
}
