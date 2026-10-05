package uk.co.workstation.wslcrm.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Apartment
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import uk.co.workstation.wslcrm.BuildConfig
import uk.co.workstation.wslcrm.app.LocalAppContainer
import uk.co.workstation.wslcrm.core.auth.SessionStore
import uk.co.workstation.wslcrm.core.auth.Workspace
import uk.co.workstation.wslcrm.core.networking.APIError
import uk.co.workstation.wslcrm.core.networking.asAPIError
import uk.co.workstation.wslcrm.core.permissions.NavigationPolicy
import uk.co.workstation.wslcrm.designsystem.AppColors
import uk.co.workstation.wslcrm.designsystem.ConfirmDialog
import uk.co.workstation.wslcrm.designsystem.DetailRow
import uk.co.workstation.wslcrm.designsystem.GroupedRow
import uk.co.workstation.wslcrm.designsystem.InlineError
import uk.co.workstation.wslcrm.designsystem.LargeButton
import uk.co.workstation.wslcrm.designsystem.LoadingState
import uk.co.workstation.wslcrm.designsystem.Notice
import uk.co.workstation.wslcrm.designsystem.SecondaryText
import uk.co.workstation.wslcrm.designsystem.Tone
import uk.co.workstation.wslcrm.designsystem.groupedSection
import uk.co.workstation.wslcrm.features.shop.ShopNavHost

/**
 * The app's root: one screen per [SessionStore.Phase] (mirrors `RootView`). Signed in, it shows
 * the tab host, rebuilt on every workspace change so each screen fetches for the new tenant.
 */
@Composable
fun RootScreen() {
    val session = LocalAppContainer.current.session
    LaunchedEffect(Unit) { session.restore() }
    when (val phase = session.phase) {
        SessionStore.Phase.Restoring -> LoadingState(Modifier.background(AppColors.groupedBackground))
        SessionStore.Phase.SignedOut -> SignInScreen(session)
        is SessionStore.Phase.TwoFactor -> TwoFactorScreen(session, phase.challenge.email)
        SessionStore.Phase.Locked -> LockedScreen(session)
        SessionStore.Phase.ChoosingWorkspace -> WorkspacePickerScreen(session, initial = true, onDone = {})
        SessionStore.Phase.SignedIn -> key(session.workspaceGeneration) { MainScreen(session) }
    }
}

/** Runs a suspend action, turning a failure into an [APIError] for display. */
private suspend fun attempt(action: suspend () -> Unit): APIError? = try {
    action()
    null
} catch (e: CancellationException) {
    throw e
} catch (e: Exception) {
    e.asAPIError
}

@Composable
private fun AuthPage(content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxSize().background(AppColors.groupedBackground).verticalScroll(rememberScrollState()).imePadding().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Column(Modifier.widthIn(max = 480.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp)) { content() }
    }
}

@Composable
private fun EnvironmentBadge(name: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Default.Cloud, contentDescription = null, tint = AppColors.secondaryText, modifier = Modifier.size(16.dp))
        Spacer(Modifier.size(6.dp))
        SecondaryText("$name environment")
    }
}

@Composable
private fun SignInScreen(session: SessionStore) {
    val scope = rememberCoroutineScope()
    var identifier by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<APIError?>(null) }
    val canSubmit = identifier.isNotBlank() && password.isNotEmpty() && !busy

    fun submit() {
        if (!canSubmit) return
        busy = true
        scope.launch {
            error = attempt { session.signIn(identifier.trim(), password) }
            busy = false
        }
    }

    AuthPage {
        Text(BuildConfig.BRAND_NAME, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        EnvironmentBadge(session.environmentName)
        session.signedOutReason?.let { Notice(it, Tone.INFO, icon = Icons.Default.Info) }
        OutlinedTextField(
            identifier, { identifier = it }, Modifier.fillMaxWidth().testTag("signIn.identifier"),
            label = { Text("Email or username") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Next),
        )
        OutlinedTextField(
            password, { password = it }, Modifier.fillMaxWidth().testTag("signIn.password"),
            label = { Text("Password") }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { submit() }),
        )
        error?.let { InlineError(it) }
        LargeButton(if (busy) "Signing in…" else "Sign in", null, Tone.INFO, enabled = canSubmit) { submit() }
    }
}

@Composable
private fun TwoFactorScreen(session: SessionStore, email: String?) {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<APIError?>(null) }
    var resent by remember { mutableStateOf(false) }

    fun verify() {
        if (code.length < 4 || busy) return
        busy = true
        scope.launch {
            error = attempt { session.verifyTwoFactor(code.trim()) }
            busy = false
        }
    }

    AuthPage {
        Text("Check your email", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text("We sent a sign-in code to ${email ?: "your email address"}.", color = AppColors.secondaryText)
        OutlinedTextField(
            code, { new -> code = new.filter(Char::isDigit).take(8) }, Modifier.fillMaxWidth().testTag("twoFactor.code"),
            label = { Text("Code") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { verify() }),
        )
        error?.let { InlineError(it) }
        if (resent) Notice("A new code is on its way.", Tone.SUCCESS, icon = Icons.Default.Info)
        LargeButton(if (busy) "Checking…" else "Verify", null, Tone.INFO, enabled = code.length >= 4 && !busy) { verify() }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = { session.cancelTwoFactor() }) { Text("Back") }
            TextButton(onClick = {
                scope.launch {
                    error = attempt { session.resendTwoFactorCode() }
                    resent = error == null
                }
            }) { Text("Send a new code") }
        }
    }
}

@Composable
private fun LockedScreen(session: SessionStore) {
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { session.unlock() }
    AuthPage {
        Icon(Icons.Default.Lock, contentDescription = null, modifier = Modifier.size(48.dp))
        Text("${BuildConfig.BRAND_NAME} is locked", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        LargeButton("Unlock with ${session.biometrics.displayName}", Icons.Default.Fingerprint, Tone.INFO) {
            scope.launch { session.unlock() }
        }
        TextButton(onClick = { scope.launch { session.signOut() } }) { Text("Sign out instead") }
    }
}

/** Pick the workspace to work in: required after sign-in with several memberships, or from More. */
@Composable
fun WorkspacePickerScreen(session: SessionStore, initial: Boolean, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    Scaffold(topBar = { TopAppBar(title = { Text(if (initial) "Choose a workspace" else "Workspace") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().background(AppColors.groupedBackground).padding(padding)) {
            session.permissionsError?.let { error -> item { InlineError(error) } }
            groupedSection(footer = if (initial) "You can switch later from More." else null) {
                session.workspaces.forEachIndexed { index, workspace ->
                    WorkspaceRow(workspace, selected = workspace.uuid == session.workspace?.uuid,
                        showDivider = index < session.workspaces.lastIndex, enabled = !busy) {
                        busy = true
                        scope.launch {
                            session.select(workspace)
                            busy = false
                            onDone()
                        }
                    }
                }
            }
            if (initial) {
                item {
                    TextButton(onClick = { scope.launch { session.signOut() } }, modifier = Modifier.padding(16.dp)) { Text("Sign out") }
                }
            }
        }
    }
}

@Composable
private fun WorkspaceRow(workspace: Workspace, selected: Boolean, showDivider: Boolean, enabled: Boolean, onClick: () -> Unit) {
    GroupedRow(onClick = if (enabled) onClick else null, showDivider = showDivider) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Apartment, contentDescription = null)
            Spacer(Modifier.size(12.dp))
            Column(Modifier.weight(1f)) {
                Text(workspace.name, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal)
                listOfNotNull(workspace.slug, if (workspace.isOwner) "owner" else null, if (selected) "current" else null)
                    .takeIf { it.isNotEmpty() }?.let { SecondaryText(it.joinToString(" · ")) }
            }
        }
    }
}

// MARK: - Signed in

private enum class Tab(val label: String) { SHOP("Shop"), MORE("More") }

@Composable
private fun MainScreen(session: SessionStore) {
    val navigation = NavigationPolicy(session.permissions)
    val tabs = buildList {
        if (navigation.showsShop) add(Tab.SHOP)
        add(Tab.MORE)
    }
    var selected by rememberSaveable { mutableStateOf(if (navigation.home == NavigationPolicy.Home.SHOP || navigation.showsShop) Tab.SHOP else Tab.MORE) }
    if (selected !in tabs) selected = tabs.first()

    Scaffold(
        bottomBar = {
            if (tabs.size > 1) {
                NavigationBar {
                    tabs.forEach { tab ->
                        NavigationBarItem(
                            selected = tab == selected,
                            onClick = { selected = tab },
                            icon = { Icon(if (tab == Tab.SHOP) Icons.Default.Storefront else Icons.Default.MoreHoriz, contentDescription = null) },
                            label = { Text(tab.label) },
                            modifier = Modifier.testTag("tab.${tab.name.lowercase()}"),
                        )
                    }
                }
            }
        },
    ) { padding ->
        Column(Modifier.padding(bottom = padding.calculateBottomPadding())) {
            when (selected) {
                Tab.SHOP -> ShopNavHost()
                Tab.MORE -> MoreScreen(session, showsShop = navigation.showsShop)
            }
        }
    }
}

@Composable
private fun MoreScreen(session: SessionStore, showsShop: Boolean) {
    val scope = rememberCoroutineScope()
    var choosingWorkspace by remember { mutableStateOf(false) }
    var confirmingSignOut by remember { mutableStateOf(false) }
    if (choosingWorkspace) {
        WorkspacePickerScreen(session, initial = false) { choosingWorkspace = false }
        androidx.activity.compose.BackHandler { choosingWorkspace = false }
        return
    }
    Scaffold(topBar = { TopAppBar(title = { Text("More") }) }) { padding ->
        LazyColumn(Modifier.fillMaxSize().background(AppColors.groupedBackground).padding(padding)) {
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
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Text("Workspace")
                            Text(session.workspace?.name ?: "None", color = AppColors.secondaryText)
                        }
                    }
                }
            }
            session.permissionsError?.let { error -> item { InlineError(error) { scope.launch { session.reloadPermissions() } } } }
            if (!showsShop) {
                item {
                    Notice(
                        "This workspace doesn't use the shop back office. The other modules (field service, CRM, projects) are on their way to the Android app.",
                        Tone.INFO, Modifier.padding(16.dp), Icons.Default.Info,
                    )
                }
            }
            groupedSection("About") {
                DetailRow("Environment", session.environmentName)
                DetailRow("Version", BuildConfig.VERSION_NAME, showDivider = false)
            }
            groupedSection {
                GroupedRow(onClick = { confirmingSignOut = true }, showDivider = false) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.AutoMirrored.Filled.Logout, contentDescription = null, tint = Tone.DANGER.textColor)
                        Spacer(Modifier.size(12.dp))
                        Text("Sign out", color = Tone.DANGER.textColor)
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
