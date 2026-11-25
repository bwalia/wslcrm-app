package uk.co.workstation.wslcrm.features.assistant

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors `CommandRouterTests.swift`: places open at once, everything else is a job for the agent. */
class CommandRouterTest {
    private val places = listOf("shop" to "Shop", "crm_leads" to "Leads", "my_tasks" to "My tasks", "products" to "Products",
        "invoices" to "Invoices").map { (key, name) -> CommandRouter.Place(key, name, null, CommandRouter.aliases[key].orEmpty()) }

    @Test fun placeNamesOpenDirectly() {
        for (text in listOf("shop", "Open shop", "open the Shop page please", "go to leads", "Show me my tasks", "tasks",
            "take me to the stock screen", "lead", "Invoices.")) {
            assertTrue(text, CommandRouter.decide(text, places) is CommandRouter.Decision.Open)
        }
        assertEquals(CommandRouter.Decision.Open(places[3]), CommandRouter.decide("stock", places))
    }

    @Test fun anythingMoreGoesToTheAgent() {
        for (text in listOf("Which open quotes should I chase first?", "show overdue invoices for Acme", "create a lead for Jane")) {
            assertEquals(CommandRouter.Decision.Ask(text), CommandRouter.decide(text, places))
        }
        assertNull(CommandRouter.decide("  ", places))
    }

    @Test fun searchRanksExactThenPrefix() {
        assertEquals("crm_leads", CommandRouter.search("le", places).first().key)
        assertEquals(listOf("products"), CommandRouter.search("inventory", places).map { it.key })
        assertTrue(CommandRouter.search("x", places).isEmpty())
    }

    @Test fun suggestionsLeadWithWhatNeedsThePerson() {
        val suggestions = CommandRouter.suggestions(listOf("shop.quotes"))
        assertEquals("Which open quotes should I chase first?", suggestions.first())
        assertTrue(suggestions.size <= 5)
    }

    @Test fun agentActionsMapToScreens() {
        val actions = listOf(
            AgentAction("call_api", "GET /api/v2/crm/leads", "GET"),
            AgentAction("call_api", "GET /api/v2/shop/admin/quotes", "GET"),
            AgentAction("call_api", "GET /api/v2/invoices", error = "Forbidden"),
            AgentAction("ask_user"),
        )
        assertEquals(listOf("crm_leads", "shop"), AgentActionScreens.keys(actions))
    }

    @Test fun conversationDecodes() {
        val json = Json.parseToJsonElement("""
            {"run_uuid":"r-1","status":"running","changed":false,
             "scope":{"key":"general","title":"Assistant","suggestions":["Do X"]},
             "pending":{"summary":"Delete lead Jane"},
             "turns":[{"role":"user","content":"find Jane"},
                      {"role":"assistant","content":"Found her","actions":[{"name":"call_api","label":"GET /api/v2/crm/leads","error":{"message":"nope"}}]}]}
        """)
        val conversation = AgentConversation.decode(json)
        assertTrue(conversation.isRunning)
        assertEquals("r-1", conversation.runUuid)
        assertEquals("find Jane", conversation.lastRequest)
        assertEquals("Delete lead Jane", conversation.pendingSummary)
        assertEquals("nope", conversation.turns[1].actions.single().error)
        assertEquals(listOf("Do X"), conversation.suggestions)
    }
}
