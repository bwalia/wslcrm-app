package uk.co.workstation.wslcrm.features.assistant

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uk.co.workstation.wslcrm.app.LocalAppContainer
import uk.co.workstation.wslcrm.core.auth.SessionStore
import uk.co.workstation.wslcrm.core.networking.asAPIError
import uk.co.workstation.wslcrm.designsystem.AppColors
import uk.co.workstation.wslcrm.designsystem.SecondaryText
import uk.co.workstation.wslcrm.designsystem.Tone
import uk.co.workstation.wslcrm.features.menu.AppMenu
import uk.co.workstation.wslcrm.features.menu.menuIcon

/**
 * The AI agent, native: tell it a job and it does it in the workspace with the person's permissions, asking when a
 * detail is missing and waiting for Confirm before anything is deleted. Replies offer "Open …" for the screens the
 * agent worked in, and typing a screen's name just opens it. Mirrors `ChatAssistantView.swift`.
 *
 * [ask] is sent once, as soon as the conversation has loaded (Home's command box hands requests over this way).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AssistantScreen(
    session: SessionStore,
    ask: String? = null,
    onOpen: (AppMenu.Item) -> Unit,
    onBack: (() -> Unit)? = null,
) {
    val api = LocalAppContainer.current.agent
    val scope = rememberCoroutineScope()
    var conversation by remember { mutableStateOf<AgentConversation?>(null) }
    var draft by rememberSaveable { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // What just happened ("Confirmed.", "Cancelled.", "New conversation."), said in the composer like iOS does.
    var notice by remember { mutableStateOf<String?>(null) }
    var deciding by remember { mutableStateOf(false) }
    var askSent by rememberSaveable { mutableStateOf(false) }
    val listState = rememberLazyListState()
    val places = remember(session.menu) { CommandRouter.places(session.menu) }

    /** Runs [action]; on failure shows the reason and returns false. A 409 means a run is already going (another
     * device, a double tap): reload so the reply is followed, as iOS does. */
    suspend fun guarded(action: suspend () -> Unit): Boolean {
        try {
            action()
            return true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val err = e.asAPIError
            error = err.message
            if (err.serverError?.status == 409) runCatching { conversation = api.conversation() }
            return false
        }
    }

    fun decide(approve: Boolean) {
        if (deciding) return
        deciding = true
        error = null
        scope.launch {
            if (guarded { conversation = api.confirm(approve) }) notice = if (approve) "Confirmed." else "Cancelled. Nothing was changed."
            deciding = false
        }
    }

    fun itemFor(key: String): AppMenu.Item? = session.menu.sections.flatMap { it.items }.firstOrNull { it.key == key }

    fun send(text: String) {
        val content = text.trim()
        if (content.isEmpty() || sending || conversation?.isRunning == true) return
        // "Open leads", "show me my tasks": just go there.
        val decision = CommandRouter.decide(content, places)
        if (decision is CommandRouter.Decision.Open && decision.place.key != AppMenu.AI_CHAT_KEY) {
            itemFor(decision.place.key)?.let { draft = ""; onOpen(it); return }
        }
        if (content.length > 4000) { error = "That's a bit long for one message — keep it under 4,000 characters."; return }
        sending = true
        error = null
        notice = null
        draft = ""
        scope.launch {
            // A failed send puts the message back in the box, so nothing typed is lost.
            if (!guarded { conversation = api.send(content) } && draft.isEmpty()) draft = content
            sending = false
        }
    }

    LaunchedEffect(Unit) {
        guarded { conversation = api.conversation() }
        if (conversation == null) conversation = AgentConversation(status = AgentConversation.Status.IDLE, turns = emptyList())
        val queued = ask?.trim()?.takeIf { it.isNotEmpty() }
        if (queued != null && !askSent) {
            askSent = true
            if (conversation?.isRunning == true) {
                draft = queued
                error = "The assistant is still finishing your last request. Your new one is in the box — send it when it's done."
            } else {
                send(queued)
            }
        }
    }
    // While a run is going, check now and then: it finishes on the server whatever happens here.
    LaunchedEffect(conversation?.isRunning) {
        while (conversation?.isRunning == true) {
            delay(2500)
            guarded { conversation = api.conversation() }
        }
    }
    val turnCount = conversation?.turns?.size ?: 0
    LaunchedEffect(turnCount, conversation?.isRunning, conversation?.pendingSummary) {
        val count = listState.layoutInfo.totalItemsCount
        if (count > 0) listState.animateScrollToItem(count - 1)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("AI Assistant", fontWeight = FontWeight.SemiBold)
                        SecondaryText("Acts in ${session.workspace?.name ?: "your workspace"} with your permissions", maxLines = 1)
                    }
                },
                navigationIcon = {
                    if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                },
                actions = {
                    IconButton(
                        onClick = {
                            scope.launch {
                                if (guarded { api.reset(); conversation = api.conversation() }) notice = "New conversation started."
                            }
                        },
                        enabled = conversation?.isRunning != true && turnCount > 0,
                        modifier = Modifier.testTag("assistant.new"),
                    ) { Icon(Icons.Default.EditNote, "New conversation") }
                },
            )
        },
        bottomBar = {
            Composer(
                draft = draft,
                onDraft = { draft = it },
                busy = sending || conversation?.isRunning == true,
                error = error,
                onDismissError = { error = null },
                notice = notice,
                onDismissNotice = { notice = null },
                onSend = { send(draft) },
            )
        },
    ) { padding ->
        val current = conversation
        Box(Modifier.fillMaxSize().background(AppColors.groupedBackground).padding(padding), contentAlignment = Alignment.TopCenter) {
            if (current == null) {
                CircularProgressIndicator(Modifier.padding(top = 48.dp))
                return@Box
            }
            LazyColumn(
                state = listState,
                modifier = Modifier.widthIn(max = 840.dp).fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (current.turns.isEmpty()) {
                    item {
                        Welcome(session.workspace?.name, current.suggestions.ifEmpty { CommandRouter.suggestions(emptyList()) }) { send(it) }
                    }
                }
                items(current.turns.size) { index ->
                    val turn = current.turns[index]
                    if (turn.isUser) UserBubble(turn.content)
                    else AssistantBubble(turn, opens = AgentActionScreens.keys(turn.actions).mapNotNull(::itemFor), onOpen = onOpen)
                }
                current.pendingSummary?.takeIf { !current.isRunning }?.let { summary ->
                    item {
                        PendingCard(summary, busy = deciding, onConfirm = { decide(true) }, onCancel = { decide(false) })
                    }
                }
                if (current.isRunning) item { Thinking() }
                if (current.changed && !current.isRunning) {
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Check, null, tint = Tone.SUCCESS.textColor, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.size(6.dp))
                            Text("This made changes in your workspace.", color = Tone.SUCCESS.textColor,
                                style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
                item {
                    SecondaryText("The assistant can create and change data in your workspace — check what it does.")
                }
            }
        }
    }
}

/** The assistant's mark: the brand accent into violet, a sparkle in the middle. */
@Composable
fun AssistantAvatar(size: Int = 32) {
    Box(
        Modifier.size(size.dp).background(
            Brush.linearGradient(listOf(MaterialTheme.colorScheme.primary, Color(0xFF5C38CC))), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Default.AutoAwesome, null, tint = Color.White, modifier = Modifier.size((size * 0.55f).dp))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Welcome(workspace: String?, suggestions: List<String>, onPick: (String) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        AssistantAvatar(56)
        Text(
            "Hi! Tell me what you need and I'll do it in ${workspace ?: "your workspace"} — customers, leads, quotes and " +
                "orders, tasks, timesheets, invoices and more. If a detail is missing, I'll ask.",
            style = MaterialTheme.typography.bodyLarge, color = AppColors.secondaryText,
        )
        suggestions.forEach { suggestion ->
            Surface(
                onClick = { onPick(suggestion) },
                shape = RoundedCornerShape(14.dp),
                color = AppColors.card,
                modifier = Modifier.fillMaxWidth().testTag("assistant.suggestion"),
            ) {
                Text(suggestion, Modifier.padding(14.dp), style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}

@Composable
private fun UserBubble(text: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Spacer(Modifier.size(44.dp))
        Text(
            text,
            Modifier.background(MaterialTheme.colorScheme.primary, RoundedCornerShape(18.dp)).padding(horizontal = 14.dp, vertical = 10.dp),
            color = MaterialTheme.colorScheme.onPrimary,
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AssistantBubble(turn: AgentTurn, opens: List<AppMenu.Item>, onOpen: (AppMenu.Item) -> Unit) {
    Row(verticalAlignment = Alignment.Top) {
        AssistantAvatar(28)
        Spacer(Modifier.size(8.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                plainMarkdown(turn.content),
                Modifier.background(AppColors.card, RoundedCornerShape(18.dp)).padding(horizontal = 14.dp, vertical = 10.dp)
                    .testTag("assistant.reply"),
                style = MaterialTheme.typography.bodyLarge,
            )
            val acted = turn.visibleActions
            if (acted.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    acted.forEach { action ->
                        val tone = if (action.error != null) Tone.DANGER else Tone.SUCCESS
                        Row(
                            Modifier.background(tone.color.copy(alpha = 0.12f), CircleShape).padding(horizontal = 10.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(if (action.error != null) Icons.Default.ErrorOutline else Icons.Default.Check, null,
                                tint = tone.textColor, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.size(4.dp))
                            Text(action.displayLabel, color = tone.textColor, style = MaterialTheme.typography.labelMedium, maxLines = 1)
                        }
                    }
                }
            }
            if (opens.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    opens.forEach { item ->
                        Row(
                            Modifier
                                .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.35f), CircleShape)
                                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.1f), CircleShape)
                                .heightIn(min = 48.dp)
                                .clickable(role = Role.Button) { onOpen(item) }
                                .padding(horizontal = 12.dp, vertical = 8.dp)
                                .testTag("assistant.open.${item.key}"),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(menuIcon(item.icon), null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.size(6.dp))
                            Text("Open ${item.name}", color = MaterialTheme.colorScheme.primary,
                                style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
        Spacer(Modifier.size(24.dp))
    }
}

@Composable
private fun PendingCard(summary: String, busy: Boolean, onConfirm: () -> Unit, onCancel: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(start = 36.dp)
            .background(Tone.DANGER.color.copy(alpha = 0.08f), RoundedCornerShape(14.dp))
            .border(1.dp, Tone.DANGER.color.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(Icons.Default.Warning, null, tint = Tone.DANGER.textColor)
            Spacer(Modifier.size(8.dp))
            Text(summary, style = MaterialTheme.typography.bodyLarge)
        }
        SecondaryText("Nothing happens until you confirm.")
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            // One answer at a time: a double tap used to send a second call that came back as a 409.
            Button(onClick = onConfirm, enabled = !busy, colors = ButtonDefaults.buttonColors(containerColor = Tone.DANGER.solidColor),
                modifier = Modifier.testTag("assistant.confirm")) { Text("Confirm") }
            OutlinedButton(onClick = onCancel, enabled = !busy, modifier = Modifier.testTag("assistant.cancel")) { Text("Cancel") }
        }
    }
}

@Composable
private fun Thinking() {
    Row(verticalAlignment = Alignment.Top, modifier = Modifier.testTag("assistant.thinking")) {
        AssistantAvatar(28)
        Spacer(Modifier.size(8.dp))
        Column(Modifier.background(AppColors.card, RoundedCornerShape(18.dp)).padding(horizontal = 14.dp, vertical = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(Modifier.size(8.dp))
                Text("Working on it…", style = MaterialTheme.typography.bodyLarge)
            }
            SecondaryText("You can leave this screen — it carries on, and the answer will be here when you're back.")
        }
    }
}

@Composable
private fun Composer(
    draft: String,
    onDraft: (String) -> Unit,
    busy: Boolean,
    error: String?,
    onDismissError: () -> Unit,
    notice: String?,
    onDismissNotice: () -> Unit,
    onSend: () -> Unit,
) {
    Surface(tonalElevation = 3.dp) {
        Column(Modifier.fillMaxWidth().imePadding().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            Column(Modifier.widthIn(max = 840.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (error != null) {
                    Row(verticalAlignment = Alignment.Top, modifier = Modifier.clickable(onClick = onDismissError).testTag("assistant.error")) {
                        Icon(Icons.Default.Warning, null, tint = Tone.DANGER.textColor, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(6.dp))
                        Text(error, style = MaterialTheme.typography.bodyMedium)
                    }
                } else if (notice != null) {
                    Row(verticalAlignment = Alignment.Top, modifier = Modifier.clickable(onClick = onDismissNotice).testTag("assistant.notice")) {
                        Icon(Icons.Default.Check, null, tint = Tone.SUCCESS.textColor, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(6.dp))
                        Text(notice, style = MaterialTheme.typography.bodyMedium, color = Tone.SUCCESS.textColor)
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = draft,
                        onValueChange = onDraft,
                        modifier = Modifier.weight(1f).testTag("assistant.composer"),
                        placeholder = { Text(if (busy) "Working on your last request…" else "Ask the assistant to do something…") },
                        enabled = !busy,
                        maxLines = 6,
                        shape = RoundedCornerShape(22.dp),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                        keyboardActions = KeyboardActions(onSend = { onSend() }),
                    )
                    Spacer(Modifier.size(8.dp))
                    FilledIconButton(onClick = onSend, enabled = !busy && draft.isNotBlank(),
                        modifier = Modifier.size(48.dp).testTag("assistant.send")) {
                        if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        else Icon(Icons.AutoMirrored.Filled.Send, "Send")
                    }
                }
            }
        }
    }
}

/** Replies are markdown; without a renderer, strip the markup so they read as plain text. */
internal fun plainMarkdown(text: String): String = text
    .replace(Regex("\\*\\*(.+?)\\*\\*"), "$1")
    .replace(Regex("(?m)^#{1,6}\\s*"), "")
    .replace(Regex("\\[([^\\]]+)]\\([^)]+\\)"), "$1")
    .replace(Regex("`([^`]+)`"), "$1")
    .replace(Regex("(?m)^\\s*[-*]\\s+"), "• ")
