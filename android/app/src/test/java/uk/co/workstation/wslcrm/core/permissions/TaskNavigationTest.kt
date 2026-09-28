package uk.co.workstation.wslcrm.core.permissions

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Who gets a Tasks home (mirrors the project-member cases in RolePermissionTests.swift). */
class TaskNavigationTest {
    private fun permissions(menuKeys: Set<String>, grants: Map<String, Set<String>>) =
        PermissionSet(isAdmin = false, isOwner = false, grants = grants, menuKeys = menuKeys)

    @Test fun someoneWhoOnlyWorksProjectsLandsOnTheirTasks() {
        val navigation = NavigationPolicy(permissions(setOf("namespace", "projects"), mapOf("projects" to setOf("read", "update"))))
        assertTrue(navigation.showsTasks)
        assertFalse("no visits, so no My Work", navigation.showsMyWork)
        assertEquals("not dropped on More with a list of menus", NavigationPolicy.Home.TASKS, navigation.home)
    }

    @Test fun fieldServiceRolesWithoutProjectsGetNoTasksTab() {
        val engineer = permissions(setOf("namespace", "field_service_jobs", "field_service_visits"),
            mapOf("fs_visits" to setOf("read"), "fs_jobs" to setOf("read")))
        val navigation = NavigationPolicy(engineer)
        assertFalse(navigation.showsTasks)
        assertEquals("engineers still land on their own work", NavigationPolicy.Home.MY_WORK, navigation.home)
    }
}
