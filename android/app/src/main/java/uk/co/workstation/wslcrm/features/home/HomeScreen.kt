package uk.co.workstation.wslcrm.features.home

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocalShipping
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import uk.co.workstation.wslcrm.app.LocalAppContainer
import uk.co.workstation.wslcrm.core.auth.SessionStore
import uk.co.workstation.wslcrm.designsystem.AppColors
import uk.co.workstation.wslcrm.designsystem.SecondaryText
import uk.co.workstation.wslcrm.designsystem.Tone
import uk.co.workstation.wslcrm.features.assistant.AssistantAvatar
import uk.co.workstation.wslcrm.features.assistant.CommandRouter
import uk.co.workstation.wslcrm.features.assistant.agent
import uk.co.workstation.wslcrm.features.menu.AppMenu
import uk.co.workstation.wslcrm.features.menu.menuIcon
import uk.co.workstation.wslcrm.features.shop.ShopKPIs
import uk.co.workstation.wslcrm.features.shop.shop
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** One count on "Needs you today", and the shop screen it belongs to. */
data class HomeSignal(val id: String, val title: String, val count: Int, val icon: ImageVector, val tone: Tone)

/** What needs the person, from the shop's dashboard (the area Android has its own screens for). */
fun homeSignals(kpis: ShopKPIs?): List<HomeSignal> {
    kpis ?: return emptyList()
    return listOf(
        HomeSignal("shop.payment", "Orders waiting for payment", kpis.pendingPayment, Icons.Default.CreditCard, Tone.WARNING),
        HomeSignal("shop.fulfil", "Orders to send", kpis.awaitingFulfilment, Icons.Default.LocalShipping, Tone.PROGRESS),
        HomeSignal("shop.quotes", "Open quotes", kpis.openQuotes, Icons.Default.Description, Tone.INFO),
        HomeSignal("shop.stock", "Products low on stock", kpis.lowStockCount, Icons.Default.Inventory2, Tone.WARNING),
    ).filter { it.count > 0 }
}

/**
 * Home: the AI agent first. One box asks "What would you like to do?" — typing searches every page in the
 * workspace ("Jump to"), a page name opens it, anything else goes to the agent, which does the job. Below it what
 * needs the person today and their apps; on a tablet or a wide window, in two columns. Mirrors `HomeView.swift`.
 */
@Composable
fun HomeScreen(
    session: SessionStore,
    showsShop: Boolean,
    onOpen: (AppMenu.Item) -> Unit,
    onOpenShop: () -> Unit,
    onAsk: (String) -> Unit,
    onContinue: () -> Unit,
) {
    val container = LocalAppContainer.current
    val canAsk = session.menu.has(AppMenu.AI_CHAT_KEY)
    var kpis by remember { mutableStateOf<ShopKPIs?>(null) }
    var lastRequest by remember { mutableStateOf<String?>(null) }
    var agentBusy by remember { mutableStateOf(false) }

    LaunchedEffect(session.workspace?.uuid) {
        if (showsShop) kpis = quietly { container.shop.dashboard() }
        if (canAsk) quietly { container.agent.conversation() }?.let {
            lastRequest = it.lastRequest
            agentBusy = it.isRunning
        }
    }
    val signals = homeSignals(kpis)
    val places = remember(session.menu) { CommandRouter.places(session.menu) }

    BoxWithConstraints(Modifier.fillMaxSize().background(AppColors.groupedBackground)) {
        val wide = maxWidth >= 840.dp
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).statusBarsPadding()
                .padding(horizontal = if (wide) 28.dp else 16.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(Modifier.widthIn(max = 1400.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                Header(session)
                val primary: @Composable ColumnScope.() -> Unit = {
                    CommandCenter(places, signals.map { it.id }, canAsk, lastRequest, agentBusy,
                        onOpen = { place ->
                            session.menu.sections.flatMap { it.items }.firstOrNull { it.key == place.key }?.let(onOpen)
                        },
                        onAsk = { lastRequest = it; agentBusy = true; onAsk(it) },
                        onContinue = onContinue)
                    if (showsShop) NeedsToday(signals, loaded = kpis != null, onOpenShop)
                }
                val secondary: @Composable ColumnScope.() -> Unit = {
                    Apps(session.menu, columns = if (wide) 3 else 4, onOpen = onOpen)
                }
                if (wide) {
                    Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.Top) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(24.dp), content = primary)
                        Column(Modifier.width(380.dp), verticalArrangement = Arrangement.spacedBy(24.dp), content = secondary)
                    }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
                        primary()
                        secondary()
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

private suspend fun <T> quietly(load: suspend () -> T): T? = try {
    load()
} catch (e: CancellationException) {
    throw e
} catch (_: Exception) {
    null
}

// MARK: - Header

@Composable
private fun Header(session: SessionStore) {
    val hour = LocalTime.now().hour
    val part = when (hour) { in 5..11 -> "Good morning"; in 12..16 -> "Good afternoon"; else -> "Good evening" }
    val name = session.user?.firstName?.takeIf { it.isNotBlank() }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(LocalDate.now().format(DateTimeFormatter.ofPattern("EEEE d MMMM", Locale.getDefault())).uppercase(),
                style = MaterialTheme.typography.labelMedium, color = AppColors.secondaryText, letterSpacing = MaterialTheme.typography.labelMedium.letterSpacing * 1.5f)
            Text(if (name != null) "$part, $name" else part, style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            session.workspace?.let { SecondaryText(it.name, maxLines = 1) }
        }
        session.user?.let { user ->
            Text(user.initials, color = Color.White, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.background(MaterialTheme.colorScheme.primary, CircleShape).padding(14.dp))
        }
    }
}

// MARK: - Command box

private val navy = Color(0xFF0D0B21)
private val indigo = Color(0xFF2C2559)
private val onDarkInk = Color(0xFFE9E7F5)
private val onDarkMuted = Color(0xFFA19DC2)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CommandCenter(
    places: List<CommandRouter.Place>,
    signalIds: List<String>,
    canAsk: Boolean,
    lastRequest: String?,
    agentBusy: Boolean,
    onOpen: (CommandRouter.Place) -> Unit,
    onAsk: (String) -> Unit,
    onContinue: () -> Unit,
) {
    var text by rememberSaveable { mutableStateOf("") }
    val focus = LocalFocusManager.current

    fun go(decision: CommandRouter.Decision) {
        focus.clearFocus()
        text = ""
        when (decision) {
            is CommandRouter.Decision.Open -> onOpen(decision.place)
            is CommandRouter.Decision.Ask -> onAsk(decision.request)
        }
    }

    fun submit() {
        val decision = CommandRouter.decide(text, places) ?: return
        if (decision is CommandRouter.Decision.Ask && !canAsk) {
            CommandRouter.search(decision.request, places).firstOrNull()?.let { go(CommandRouter.Decision.Open(it)) }
            return
        }
        go(decision)
    }

    Column(
        Modifier.fillMaxWidth()
            .background(Brush.linearGradient(listOf(navy, indigo)), RoundedCornerShape(26.dp))
            .padding(20.dp)
            .testTag("home.command"),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AssistantAvatar(36)
            Spacer(Modifier.size(12.dp))
            Column {
                Text(if (canAsk) "What would you like to do?" else "Where would you like to go?",
                    style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = Color.White)
                Text(if (canAsk) "Ask, search or give me a job — I'll open the right screen or do it for you."
                    else "Type the name of any page in your workspace.",
                    style = MaterialTheme.typography.bodyMedium, color = onDarkMuted)
            }
        }

        Row(
            Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(22.dp))
                .border(1.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(22.dp))
                .padding(start = 8.dp, end = 6.dp, top = 2.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.AutoAwesome, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 8.dp))
            TextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.weight(1f).testTag("home.command.field"),
                placeholder = { Text(if (canAsk) "e.g. “Which quotes should I chase?”" else "Search pages…", color = onDarkMuted) },
                maxLines = 4,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = Color.White),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                    cursorColor = Color.White,
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { submit() }),
            )
            if (text.isNotBlank()) {
                IconButton(onClick = { text = "" }) { Icon(Icons.Default.Close, "Clear", tint = onDarkMuted) }
            }
            FilledIconButton(
                onClick = { submit() },
                enabled = text.isNotBlank(),
                colors = IconButtonDefaults.filledIconButtonColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                    disabledContainerColor = Color.White.copy(alpha = 0.15f),
                    disabledContentColor = onDarkMuted,
                ),
                modifier = Modifier.size(44.dp).testTag("home.command.go"),
            ) { Icon(Icons.Default.ArrowUpward, "Go") }
        }

        val query = text.trim()
        if (query.isNotEmpty()) {
            val matches = CommandRouter.search(query, places)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                if (canAsk) {
                    ResultRow(Icons.Default.AutoAwesome, "Ask AI", "“$query”", "ask") { go(CommandRouter.Decision.Ask(query)) }
                } else if (matches.isEmpty()) {
                    Text("Nothing in your workspace is called that.", color = onDarkMuted, style = MaterialTheme.typography.bodyMedium)
                }
                if (matches.isNotEmpty()) {
                    Text("JUMP TO", color = onDarkMuted, style = MaterialTheme.typography.labelMedium,
                        modifier = Modifier.padding(top = 8.dp, start = 6.dp))
                    matches.forEach { place ->
                        ResultRow(menuIcon(place.icon), place.name, null, place.key) { go(CommandRouter.Decision.Open(place)) }
                    }
                }
            }
        } else if (canAsk) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                CommandRouter.suggestions(signalIds).forEach { prompt ->
                    Text(prompt, color = onDarkInk, style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.background(Color.White.copy(alpha = 0.1f), CircleShape)
                            .border(1.dp, Color.White.copy(alpha = 0.12f), CircleShape)
                            .clickable { go(CommandRouter.Decision.Ask(prompt)) }
                            .padding(horizontal = 14.dp, vertical = 9.dp)
                            .testTag("home.command.suggestion"))
                }
            }
            if (lastRequest != null) {
                Row(
                    Modifier.fillMaxWidth().background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(14.dp))
                        .clickable(onClick = onContinue).padding(12.dp).testTag("home.command.continue"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Replay, null, tint = onDarkInk)
                    Spacer(Modifier.size(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(if (agentBusy) "Working on your last request" else "Continue where you left off",
                            color = onDarkMuted, style = MaterialTheme.typography.labelMedium)
                        Text(lastRequest, color = onDarkInk, style = MaterialTheme.typography.bodyLarge, maxLines = 1,
                            overflow = TextOverflow.Ellipsis)
                    }
                    Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = onDarkMuted)
                }
            }
        }
    }
}

@Composable
private fun ResultRow(icon: ImageVector, title: String, detail: String?, id: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable(onClick = onClick).padding(6.dp).testTag("home.command.result.$id"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = onDarkInk, modifier = Modifier.background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(9.dp)).padding(7.dp))
        Spacer(Modifier.size(12.dp))
        Text(title, color = onDarkInk, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        if (detail != null) {
            Spacer(Modifier.size(8.dp))
            Text(detail, color = onDarkMuted, style = MaterialTheme.typography.bodyMedium, maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        } else {
            Spacer(Modifier.weight(1f))
        }
        Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = onDarkMuted, modifier = Modifier.size(18.dp))
    }
}

// MARK: - Needs you today

@Composable
private fun SectionTitle(text: String) {
    Text(text.uppercase(), style = MaterialTheme.typography.labelLarge, color = AppColors.secondaryText,
        modifier = Modifier.padding(start = 4.dp, bottom = 10.dp))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun NeedsToday(signals: List<HomeSignal>, loaded: Boolean, onOpenShop: () -> Unit) {
    if (!loaded) return
    Column {
        SectionTitle("Needs you today")
        if (signals.isEmpty()) {
            Text("Nothing is waiting for you. Nice work.", color = Tone.SUCCESS.textColor, style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.fillMaxWidth().background(AppColors.card, RoundedCornerShape(16.dp)).padding(16.dp))
            return@Column
        }
        BoxWithConstraints {
            val perRow = if (maxWidth >= 600.dp) minOf(signals.size, 4) else 2
            val gap = 10.dp
            val tileWidth = (maxWidth - gap * (perRow - 1)) / perRow
            FlowRow(horizontalArrangement = Arrangement.spacedBy(gap), verticalArrangement = Arrangement.spacedBy(gap)) {
                signals.forEach { signal ->
                    Column(
                        Modifier.width(tileWidth).background(AppColors.card, RoundedCornerShape(18.dp))
                            .clickable(onClick = onOpenShop).padding(14.dp).testTag("home.signal.${signal.id}"),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(signal.icon, null, tint = signal.tone.textColor,
                            modifier = Modifier.background(signal.tone.color.copy(alpha = 0.14f), RoundedCornerShape(9.dp)).padding(6.dp))
                        Text("%,d".format(signal.count), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                        Text(signal.title, style = MaterialTheme.typography.bodyMedium, maxLines = 2)
                    }
                }
            }
        }
    }
}

// MARK: - Apps

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Apps(menu: AppMenu, columns: Int, onOpen: (AppMenu.Item) -> Unit) {
    val items = menu.sections.flatMap { it.items }.filter { it.key !in setOf("dashboard", "apps", AppMenu.AI_CHAT_KEY) }
        .distinctBy { it.key }.take(12)
    if (items.isEmpty()) return
    Column {
        SectionTitle("Your apps")
        BoxWithConstraints(Modifier.fillMaxWidth().background(AppColors.card, RoundedCornerShape(20.dp)).padding(12.dp)) {
            val cell = maxWidth / columns
            FlowRow(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                items.forEach { item ->
                    Column(
                        Modifier.width(cell).clickable { onOpen(item) }.padding(vertical = 6.dp).testTag("home.app.${item.key}"),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(menuIcon(item.icon), null, tint = Color.White, modifier = Modifier.size(52.dp)
                            .background(tileColor(item.key), RoundedCornerShape(15.dp)).padding(13.dp))
                        Text(item.name, style = MaterialTheme.typography.labelLarge, textAlign = TextAlign.Center,
                            maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 4.dp))
                    }
                }
            }
        }
    }
}

private val tileColors = listOf(
    Color(0xFFD60040), Color(0xFF5C38CC), Color(0xFF006BBF), Color(0xFF00736B),
    Color(0xFF1C7333), Color(0xFFB35400), Color(0xFF9E218C), Color(0xFF38405C),
)

/** A stable colour per area, as on iOS (`Palette.tile(for:)`). */
private fun tileColor(key: String): Color {
    var sum = 0
    for (c in key) sum = (sum * 31 + c.code) and 0xFFFF
    return tileColors[sum % tileColors.size]
}
