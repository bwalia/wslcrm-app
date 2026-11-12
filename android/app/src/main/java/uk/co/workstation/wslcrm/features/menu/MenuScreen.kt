package uk.co.workstation.wslcrm.features.menu

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.AccountBalance
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Assignment
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Contacts
import androidx.compose.material.icons.filled.Dashboard
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.SmartToy
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.material.icons.filled.ViewKanban
import androidx.compose.material.icons.filled.Webhook
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uk.co.workstation.wslcrm.BuildConfig
import uk.co.workstation.wslcrm.app.ui.WorkspacePickerScreen
import uk.co.workstation.wslcrm.core.auth.SessionStore
import uk.co.workstation.wslcrm.designsystem.AppColors
import uk.co.workstation.wslcrm.designsystem.ConfirmDialog
import uk.co.workstation.wslcrm.designsystem.DetailRow
import uk.co.workstation.wslcrm.designsystem.GroupedRow
import uk.co.workstation.wslcrm.designsystem.InlineError
import uk.co.workstation.wslcrm.designsystem.SecondaryText
import uk.co.workstation.wslcrm.designsystem.Tone
import uk.co.workstation.wslcrm.designsystem.groupedSection

/**
 * The Menu tab: the web dashboard's sidebar on the phone. Same groups, same order, same items for
 * the same person and workspace — the server applies the workspace's modules and the person's
 * permissions. The shop opens the app's own screens; everything else opens the web page, signed in,
 * inside the app. Mirrors `Features/Menu/MenuView.swift`.
 */
@Composable
fun MenuScreen(session: SessionStore, onOpenShop: () -> Unit) {
    val scope = rememberCoroutineScope()
    var choosingWorkspace by remember { mutableStateOf(false) }
    var confirmingSignOut by remember { mutableStateOf(false) }
    var open by remember { mutableStateOf<WebPageRoute?>(null) }
    var search by rememberSaveable { mutableStateOf("") }

    open?.let { route ->
        BackHandler { open = null }
        WebPageScreen(session, route, onBack = { open = null })
        return
    }
    if (choosingWorkspace) {
        BackHandler { choosingWorkspace = false }
        WorkspacePickerScreen(session, initial = false) { choosingWorkspace = false }
        return
    }

    fun openItem(item: AppMenu.Item) {
        when (val destination = MenuDestination.of(item)) {
            MenuDestination.Shop -> onOpenShop()
            is MenuDestination.Web -> open = destination.route.copy(title = title(item))
            null -> Unit
        }
    }

    Scaffold(topBar = { TopAppBar(title = { Text("Menu") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().background(AppColors.groupedBackground).padding(padding)) {
            item {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    placeholder = { Text("Search the menu") },
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("menu.search"),
                )
            }
            if (search.isBlank()) {
                session.user?.let { user ->
                    groupedSection {
                        GroupedRow {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(user.initials, fontWeight = FontWeight.Bold, modifier = Modifier
                                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.15f), CircleShape).padding(14.dp))
                                Spacer(Modifier.size(14.dp))
                                Column {
                                    Text(user.displayName, fontWeight = FontWeight.SemiBold)
                                    SecondaryText(user.email)
                                }
                            }
                        }
                        GroupedRow(onClick = if (session.workspaces.size > 1) ({ choosingWorkspace = true }) else null, showDivider = false) {
                            Row(Modifier.fillMaxWidth().testTag("menu.workspace"), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text(if (session.workspaces.size > 1) "Workspace · switch" else "Workspace")
                                Text(session.workspace?.name ?: "None", color = AppColors.secondaryText)
                            }
                        }
                    }
                }
            }
            session.permissionsError?.let { error -> item { InlineError(error) { scope.launch { session.reloadPermissions() } } } }

            val sections = session.menu.filtered(search)
            val settings = if (search.isBlank()) emptyList()
            else session.menu.secondary.filter { title(it).contains(search.trim(), ignoreCase = true) }
            if (search.isNotBlank() && sections.isEmpty() && settings.isEmpty()) {
                item { SecondaryText("Nothing in your menu matches “${search.trim()}”.", Modifier.padding(24.dp)) }
            }
            sections.forEach { section ->
                groupedSection(title = section.title, key = section.key ?: "_top") {
                    section.items.forEachIndexed { index, item ->
                        MenuRow(item, showDivider = index < section.items.lastIndex) { openItem(item) }
                    }
                }
            }
            if (settings.isNotEmpty()) {
                groupedSection(key = "_settings_search") {
                    settings.forEachIndexed { index, item -> MenuRow(item, index < settings.lastIndex) { openItem(item) } }
                }
            }

            if (search.isBlank()) {
                groupedSection(key = "_app") {
                    session.menu.secondary.forEach { item -> MenuRow(item, showDivider = true) { openItem(item) } }
                    DetailRow("Environment", session.environmentName)
                    DetailRow("Version", BuildConfig.VERSION_NAME, showDivider = false)
                }
                groupedSection(key = "_signout") {
                    GroupedRow(onClick = { confirmingSignOut = true }, showDivider = false) {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag("more.signOut")) {
                            Icon(Icons.AutoMirrored.Filled.Logout, contentDescription = null, tint = Tone.DANGER.textColor)
                            Spacer(Modifier.size(12.dp))
                            Text("Sign out", color = Tone.DANGER.textColor)
                        }
                    }
                }
            }
        }
    }
    if (confirmingSignOut) {
        ConfirmDialog("Sign out of ${BuildConfig.BRAND_NAME}?", null, "Sign out", destructive = true,
            onConfirm = { scope.launch { session.signOut() } }, onDismiss = { confirmingSignOut = false })
    }
}

/** The web calls the workspace's settings just "Settings"; next to the app's own, that needs saying. */
private fun title(item: AppMenu.Item): String = if (item.key == "settings") "Workspace settings" else item.name

@Composable
private fun MenuRow(item: AppMenu.Item, showDivider: Boolean, onClick: () -> Unit) {
    val opens = MenuDestination.of(item) != null
    GroupedRow(onClick = if (opens) onClick else null, showDivider = showDivider) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.testTag("menu.item.${item.key}")) {
            Icon(menuIcon(item.icon), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.size(14.dp))
            Text(title(item), color = if (opens) MaterialTheme.colorScheme.onSurface else AppColors.secondaryText)
        }
    }
}

/** Material icons for the Lucide names the web menu uses. Unknown names get a neutral tile. */
fun menuIcon(lucide: String?): ImageVector = when (lucide) {
    "LayoutDashboard", "LayoutGrid", "Gauge" -> Icons.Default.Dashboard
    "Users", "UserCircle", "Contact", "Handshake" -> Icons.Default.People
    "UserPlus" -> Icons.Default.PersonAdd
    "Wallet", "CreditCard", "DollarSign" -> Icons.Default.AccountBalanceWallet
    "Landmark", "Calculator" -> Icons.Default.AccountBalance
    "ShoppingCart", "ShoppingBag" -> Icons.Default.ShoppingCart
    "Store" -> Icons.Default.Storefront
    "Package", "Boxes" -> Icons.Default.Inventory2
    "Kanban", "FolderKanban" -> Icons.Default.ViewKanban
    "ListTodo", "CheckSquare", "ClipboardCheck" -> Icons.Default.Checklist
    "ClipboardList", "ScrollText", "NotebookPen" -> Icons.Default.Assignment
    "FileText", "FileUp", "LayoutTemplate", "Receipt" -> Icons.Default.Description
    "Clock", "Timer", "CalendarDays", "Calendar" -> Icons.Default.Schedule
    "MessageSquare", "MessageCircle", "Inbox" -> Icons.Default.Forum
    "Bot", "Sparkles" -> Icons.Default.SmartToy
    "BarChart", "BarChart3", "Activity", "PieChart" -> Icons.Default.BarChart
    "Building", "Building2", "Briefcase" -> Icons.Default.Business
    "Hammer", "Wrench" -> Icons.Default.Build
    "BookOpen", "GraduationCap" -> Icons.Default.MenuBook
    "Shield", "ShieldCheck", "ShieldOff", "Lock" -> Icons.Default.Security
    "Key", "KeyRound" -> Icons.Default.Key
    "Webhook" -> Icons.Default.Webhook
    "Settings" -> Icons.Default.Settings
    else -> Icons.Default.Apps
}
