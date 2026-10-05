package uk.co.workstation.wslcrm.features.shop

import android.content.Intent
import androidx.core.net.toUri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import kotlinx.coroutines.delay
import uk.co.workstation.wslcrm.core.networking.APIError
import uk.co.workstation.wslcrm.designsystem.AppColors
import uk.co.workstation.wslcrm.designsystem.ConfirmDialog
import uk.co.workstation.wslcrm.designsystem.DetailRow
import uk.co.workstation.wslcrm.designsystem.EmptyState
import uk.co.workstation.wslcrm.designsystem.ErrorState
import uk.co.workstation.wslcrm.designsystem.Formatters
import uk.co.workstation.wslcrm.designsystem.GroupedRow
import uk.co.workstation.wslcrm.designsystem.InlineError
import uk.co.workstation.wslcrm.designsystem.LoadState
import uk.co.workstation.wslcrm.designsystem.LoadingState
import uk.co.workstation.wslcrm.designsystem.PagedListModel
import uk.co.workstation.wslcrm.designsystem.PagedListScreen
import uk.co.workstation.wslcrm.designsystem.SearchField
import uk.co.workstation.wslcrm.designsystem.SecondaryText
import uk.co.workstation.wslcrm.designsystem.StatusBadge
import uk.co.workstation.wslcrm.designsystem.Tone
import uk.co.workstation.wslcrm.designsystem.groupedSection
import uk.co.workstation.wslcrm.designsystem.trimmedOrNull
import java.text.NumberFormat
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - Assistant chats

@Composable
fun ShopChatsScreen(nav: NavHostController) {
    val api = shopApi
    val model = viewModel(key = "shop.chats") {
        PagedListModel<ShopChatSession>({ it.uuid }, { search, page -> api.chats(search, page) })
    }
    ShopScaffold("Assistant chats", nav) { modifier ->
        PagedListScreen(model, "Email or message text", "No chats", Icons.Default.Chat,
            emptyDescription = "Conversations customers have with the shop assistant appear here.", modifier = modifier) { chat ->
            GroupedRow(onClick = { nav.navigate(ShopRoutes.chat(chat.uuid)) }, showDivider = false) {
                Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Row {
                        Text(chat.email ?: "Anonymous visitor", fontWeight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f))
                        SecondaryText(Formatters.relative(chat.updatedAt ?: chat.createdAt).orEmpty())
                    }
                    (chat.summary?.trimmedOrNull ?: chat.firstUserMessage?.trimmedOrNull)?.let { Text(it, maxLines = 2) }
                    SecondaryText(listOfNotNull("${chat.messageCount} message${if (chat.messageCount == 1) "" else "s"}",
                        chat.quoteNumber?.let { "quote $it" }, chat.orderNumber?.let { "order $it" }).joinToString(" · "))
                }
            }
        }
    }
}

@Composable
fun ShopChatDetailScreen(nav: NavHostController, uuid: String) {
    val api = shopApi
    val loader = rememberLoader(uuid) { api.chat(uuid) }
    ShopScaffold(loader.value?.email ?: "Chat", nav) { modifier ->
        when (val state = loader.state) {
            LoadState.Idle, LoadState.Loading -> LoadingState(modifier)
            is LoadState.Failed -> ErrorState(state.error, modifier) { loader.reload() }
            is LoadState.Loaded -> {
                val chat = state.value
                val messages = chat.messages.filter { it.role in setOf("user", "assistant") && it.content.isNotBlank() }
                LazyColumn(modifier, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    chat.summary?.trimmedOrNull?.let { summary ->
                        item {
                            Text(summary, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.fillMaxWidth()
                                .background(AppColors.card, RoundedCornerShape(12.dp)).padding(12.dp))
                        }
                    }
                    items(messages) { ChatBubble(it) }
                }
            }
        }
    }
}

@Composable
private fun ChatBubble(message: ShopChatMessage) {
    val customer = message.isCustomer
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (customer) Arrangement.End else Arrangement.Start) {
        Column(horizontalAlignment = if (customer) Alignment.End else Alignment.Start, modifier = Modifier.widthIn(max = 320.dp)) {
            SelectionContainer {
                Text(message.content, color = if (customer) Color.White else MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.background(if (customer) Tone.INFO.solidColor else AppColors.card, RoundedCornerShape(16.dp)).padding(12.dp))
            }
            SecondaryText(listOfNotNull(if (customer) "Customer" else "Assistant", Formatters.time(message.at)).joinToString(" · "),
                Modifier.padding(top = 2.dp))
        }
    }
}

// MARK: - Knowledge

@Composable
fun ShopKnowledgeScreen(nav: NavHostController) {
    val api = shopApi
    val policy = shopPolicy
    val actions = rememberActions()
    var generation by remember { mutableIntStateOf(0) }
    var adding by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<ShopKnowledgeDoc?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val model = viewModel(key = "shop.knowledge.$generation") {
        PagedListModel<ShopKnowledgeDoc>({ it.id }, { search, page -> api.knowledge(search, page) })
    }

    ShopScaffold("Assistant knowledge", nav, actions = {
        if (policy.canUpdate) IconButton(onClick = {
            actions.run {
                notice = describeResult(api.reindexKnowledge())
                generation++
            }
        }, enabled = !actions.busy) {
            if (actions.busy) CircularProgressIndicator(Modifier.size(20.dp)) else Icon(Icons.Default.Refresh, contentDescription = "Re-index products and posts")
        }
        if (policy.canCreate) IconButton(onClick = { adding = true }) { Icon(Icons.Default.Add, contentDescription = "Add document") }
    }) { modifier ->
        Column(modifier) {
            actions.error?.let { InlineError(it) }
            PagedListScreen(model, "Title or text", "Nothing indexed", Icons.AutoMirrored.Filled.LibraryBooks,
                emptyDescription = "Re-index to give the shop assistant your products and blog posts.") { doc ->
                GroupedRow(showDivider = false) {
                    Row(verticalAlignment = Alignment.Top) {
                        Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Row {
                                Text(doc.title, fontWeight = FontWeight.SemiBold, maxLines = 2, modifier = Modifier.weight(1f))
                                SecondaryText(Formatters.humanize(doc.sourceType))
                            }
                            doc.preview?.trimmedOrNull?.let { SecondaryText(it, maxLines = 3) }
                            val embedded = doc.chunks > 0 && doc.embeddedChunks == doc.chunks
                            SecondaryText("${doc.chunks} chunk${if (doc.chunks == 1) "" else "s"} · ${if (embedded) "embedded" else "text search only"}")
                        }
                        if (policy.canDelete) IconButton(onClick = { removing = doc }) {
                            Icon(Icons.Default.Delete, contentDescription = "Remove ${doc.title}", tint = Tone.DANGER.textColor)
                        }
                    }
                }
            }
        }
    }
    if (adding) KnowledgeSheet(onDismiss = { adding = false }) {
        adding = false
        generation++
    }
    removing?.let { doc ->
        ConfirmDialog("Remove “${doc.title}”?", "The shop assistant stops using it.", "Remove", destructive = true,
            onConfirm = { actions.run { api.deleteKnowledge(doc); model.remove(doc.id) } }, onDismiss = { removing = null })
    }
    notice?.let { text ->
        AlertDialog(onDismissRequest = { notice = null }, title = { Text("Re-indexed") }, text = { Text(text) },
            confirmButton = { TextButton(onClick = { notice = null }) { Text("OK") } })
    }
}

@Composable
private fun KnowledgeSheet(onDismiss: () -> Unit, onSaved: () -> Unit) {
    val api = shopApi
    val actions = rememberActions()
    var kind by remember { mutableStateOf("faq") }
    var title by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("") }
    var content by remember { mutableStateOf("") }
    FormSheet("Add knowledge", saveEnabled = title.isNotBlank() && content.isNotBlank(), actions = actions, onDismiss = onDismiss, onSave = {
        actions.run(onSaved) { api.addKnowledge(ShopKnowledgeInput(kind, title.trim(), url.trimmedOrNull, content.trim())) }
    }) {
        Picker("Kind", kind, listOf("faq" to "FAQ", "manual" to "Manual", "url" to "Web page")) { kind = it }
        OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth(), label = { Text("Title") }, singleLine = true)
        OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), label = { Text("Link (optional)") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        OutlinedTextField(content, { content = it }, Modifier.fillMaxWidth(), label = { Text("What the assistant should know") },
            supportingText = { Text("The shop assistant quotes this to customers, so write it as you'd want it said.") }, minLines = 6)
    }
}

// MARK: - Market prices

@Composable
fun ShopMarketScreen(nav: NavHostController) {
    val api = shopApi
    var search by remember { mutableStateOf("") }
    var query by remember { mutableStateOf("") }
    var attentionOnly by remember { mutableStateOf(false) }
    LaunchedEffect(search) {
        delay(350)
        query = search
    }
    val loader = rememberLoader(query) { api.marketOverview(query) }

    ShopScaffold("Market prices", nav) { modifier ->
        Column(modifier) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                listOf(false to "All", true to "Needs attention").forEachIndexed { index, (value, label) ->
                    SegmentedButton(attentionOnly == value, { attentionOnly = value }, SegmentedButtonDefaults.itemShape(index, 2)) { Text(label) }
                }
            }
            SearchField(search, "Name, SKU or brand") { search = it }
            when (val state = loader.state) {
                LoadState.Idle, LoadState.Loading -> LoadingState()
                is LoadState.Failed -> ErrorState(state.error) { loader.reload() }
                is LoadState.Loaded -> PullToRefreshBox(loader.refreshing, loader::reload, Modifier.fillMaxSize()) {
                    val rows = if (attentionOnly) state.value.filter { it.needsAttention } else state.value
                    if (rows.isEmpty()) {
                        EmptyState("No tracked products", Icons.AutoMirrored.Filled.ShowChart,
                            description = "Add competitor sources to a product in the web dashboard to track market prices.")
                    } else {
                        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                            groupedSection(footer = "Market prices are ex VAT, from accepted observations in the last 7 days.") {
                                rows.forEachIndexed { index, row ->
                                    GroupedRow(onClick = { nav.navigate(ShopRoutes.marketProduct(row.productUuid, row.name)) },
                                        showDivider = index < rows.lastIndex) { MarketRowContent(row) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MarketRowContent(row: ShopMarketRow) {
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(row.name, fontWeight = FontWeight.SemiBold, maxLines = 2)
        Row {
            Text("Ours ${ShopMoney.format(row.ourPriceExVatMinor) ?: "—"}", modifier = Modifier.weight(1f))
            Text("Median ${ShopMoney.format(row.marketMedianExVatMinor) ?: "—"}")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            row.diffPct?.let { DiffBadge(it) }
            if (row.stale) StatusBadge("No fresh data", Icons.Default.Timer, Tone.WARNING)
            if (row.pendingAnomalies > 0) StatusBadge("${row.pendingAnomalies} to review", Icons.Default.Warning, Tone.WARNING)
            if (row.failingSources > 0) StatusBadge("${row.failingSources} failing", Icons.Default.ErrorOutline, Tone.DANGER)
        }
        SecondaryText("${row.sku} · ${row.freshSources}/${row.totalSources} sources fresh")
    }
}

@Composable
private fun DiffBadge(diffPct: Double) {
    val number = NumberFormat.getNumberInstance().apply { maximumFractionDigits = 1 }.format(diffPct)
    val text = "${if (diffPct > 0) "+" else ""}$number% vs market"
    when {
        abs(diffPct) <= 5 -> StatusBadge(text, Icons.Default.DragHandle, Tone.SUCCESS)
        diffPct > 0 -> StatusBadge(text, Icons.Default.ArrowUpward, Tone.WARNING)
        else -> StatusBadge(text, Icons.Default.ArrowDownward, Tone.INFO)
    }
}

@Composable
fun ShopMarketDetailScreen(nav: NavHostController, productUuid: String, title: String) {
    val api = shopApi
    val policy = shopPolicy
    val context = LocalContext.current
    val loader = rememberLoader(productUuid) { api.marketProduct(productUuid) }
    val actions = rememberActions()
    var customPrice by remember { mutableStateOf("") }
    var pending by remember { mutableStateOf<ShopApplyPriceStrategy?>(null) }

    ShopScaffold(title.ifBlank { "Market prices" }, nav) { modifier ->
        when (val state = loader.state) {
            LoadState.Idle, LoadState.Loading -> LoadingState(modifier)
            is LoadState.Failed -> if (state.error is APIError.NotFound) {
                EmptyState("Not tracked", Icons.AutoMirrored.Filled.ShowChart, modifier, "This product has no market sources yet.")
            } else {
                ErrorState(state.error, modifier) { loader.reload() }
            }
            is LoadState.Loaded -> PullToRefreshBox(loader.refreshing, loader::reload, modifier) {
                val detail = state.value
                val summary = detail.summary
                LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                    (actions.error ?: loader.refreshError)?.let { item { InlineError(it) } }
                    groupedSection("Ex VAT") {
                        DetailRow("Our price", ShopMoney.format(detail.basePriceMinor))
                        DetailRow("Market low", ShopMoney.format(summary?.minExVatMinor))
                        DetailRow("Market median", ShopMoney.format(summary?.medianExVatMinor))
                        DetailRow("Market high", ShopMoney.format(summary?.maxExVatMinor))
                        summary?.let {
                            DetailRow("Sources", "${it.sourcesTotal} fresh · ${it.sourcesInStock} in stock")
                            DetailRow("Latest", Formatters.relative(it.freshestAt), showDivider = false)
                        }
                    }
                    if (policy.canUpdate) {
                        groupedSection("Apply a price", footer = "Nothing changes prices automatically.") {
                            if (summary?.medianExVatMinor != null) {
                                GroupedRow(onClick = { pending = ShopApplyPriceStrategy.MEDIAN }) { Text("Match median", color = MaterialTheme.colorScheme.primary) }
                            }
                            if (summary?.minExVatMinor != null) {
                                GroupedRow(onClick = { pending = ShopApplyPriceStrategy.MIN }) { Text("Match lowest", color = MaterialTheme.colorScheme.primary) }
                            }
                            GroupedRow(showDivider = false) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    OutlinedTextField(customPrice, { customPrice = it }, Modifier.weight(1f), label = { Text("Custom price ex VAT") },
                                        singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                                    Spacer(Modifier.size(8.dp))
                                    OutlinedButton(onClick = { pending = ShopApplyPriceStrategy.VALUE },
                                        enabled = !actions.busy && (ShopMoney.minor(customPrice) ?: 0) > 0) { Text("Set") }
                                }
                            }
                        }
                    }
                    if (detail.sources.isNotEmpty()) {
                        groupedSection("Sources") {
                            detail.sources.forEachIndexed { index, source ->
                                GroupedRow(onClick = source.url?.let { url -> { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) } } },
                                    showDivider = index < detail.sources.lastIndex) {
                                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Row {
                                            Text(source.name, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                                            Text(ShopMoney.format(source.latestObservation?.priceExVatMinor) ?: "—")
                                        }
                                        SecondaryText(listOfNotNull(source.lastStatus?.let(Formatters::humanize),
                                            source.latestObservation?.availability?.let(Formatters::humanize),
                                            Formatters.relative(source.lastCheckedAt)).joinToString(" · "))
                                        source.lastError?.trimmedOrNull?.let { SecondaryText(it, color = Tone.DANGER.textColor, maxLines = 2) }
                                    }
                                }
                            }
                        }
                    }
                    if (detail.observations.isNotEmpty()) {
                        groupedSection("Observations") {
                            val shown = detail.observations.take(30)
                            shown.forEachIndexed { index, observation ->
                                GroupedRow(showDivider = index < shown.lastIndex) {
                                    ObservationContent(observation, canAccept = policy.canUpdate && !actions.busy) {
                                        actions.run { api.acceptObservation(observation.uuid); loader.reload() }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    pending?.let { strategy ->
        val title = when (strategy) {
            ShopApplyPriceStrategy.MEDIAN -> "Match the market median?"
            ShopApplyPriceStrategy.MIN -> "Match the lowest market price?"
            ShopApplyPriceStrategy.VALUE -> "Set price to ${ShopMoney.minor(customPrice)?.let { ShopMoney.format(it) } ?: customPrice}?"
        }
        ConfirmDialog(title, "Sets the base price (ex VAT) and marks it verified. Orders and quotes already made keep their prices.", "Set price",
            onConfirm = {
                actions.run {
                    api.applyMarketPrice(productUuid, strategy, ShopMoney.minor(customPrice))
                    customPrice = ""
                    loader.reload()
                }
            },
            onDismiss = { pending = null })
    }
}

@Composable
private fun ObservationContent(observation: ShopMarketObservation, canAccept: Boolean, onAccept: () -> Unit) {
    Row(verticalAlignment = Alignment.Top) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(observation.sourceName ?: "Source")
            SecondaryText(listOfNotNull(Formatters.dateTime(observation.fetchedAt), observation.method?.uppercase(),
                observation.confidence?.let { "${(it * 100).roundToInt()}% sure" }).joinToString(" · "))
            if (!observation.accepted) {
                val change = observation.changePct?.let { NumberFormat.getNumberInstance().apply { maximumFractionDigits = 1 }.format(it) + "% change" }
                SecondaryText("Held: ${change ?: "large change"}", color = Tone.WARNING.textColor)
            }
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(ShopMoney.format(observation.priceExVatMinor) ?: "—")
            if (!observation.accepted) OutlinedButton(onClick = onAccept, enabled = canAccept) { Text("Accept") }
        }
    }
}
