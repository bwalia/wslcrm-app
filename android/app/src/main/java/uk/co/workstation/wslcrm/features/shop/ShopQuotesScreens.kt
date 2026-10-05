package uk.co.workstation.wslcrm.features.shop

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import uk.co.workstation.wslcrm.core.events.EntityChange
import uk.co.workstation.wslcrm.core.networking.APIDate
import uk.co.workstation.wslcrm.designsystem.AppColors
import uk.co.workstation.wslcrm.designsystem.ConfirmDialog
import uk.co.workstation.wslcrm.designsystem.DetailRow
import uk.co.workstation.wslcrm.designsystem.ErrorState
import uk.co.workstation.wslcrm.designsystem.Formatters
import uk.co.workstation.wslcrm.designsystem.GroupedRow
import uk.co.workstation.wslcrm.designsystem.InlineError
import uk.co.workstation.wslcrm.designsystem.LargeButton
import uk.co.workstation.wslcrm.designsystem.LoadState
import uk.co.workstation.wslcrm.designsystem.LoadingState
import uk.co.workstation.wslcrm.designsystem.PagedListModel
import uk.co.workstation.wslcrm.designsystem.PagedListScreen
import uk.co.workstation.wslcrm.designsystem.SecondaryText
import uk.co.workstation.wslcrm.designsystem.Tone
import uk.co.workstation.wslcrm.designsystem.groupedSection
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

internal const val QUOTE_KIND = "shop.quote"

@Composable
fun ShopQuoteRowContent(quote: ShopQuote) {
    val expired = quote.isExpired()
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(quote.quoteNumber, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            quote.status.Badge()
        }
        Row {
            Text(quote.customer.displayName, style = MaterialTheme.typography.titleMedium, maxLines = 1, modifier = Modifier.weight(1f))
            Text(ShopMoney.format(quote.totalMinor, quote.currency).orEmpty(), style = MaterialTheme.typography.titleMedium)
        }
        val validity = quote.validUntil?.let { (if (expired) "Expired " else "Valid until ") + Formatters.day(it) }
        SecondaryText(listOfNotNull(quote.source?.let { "From ${Formatters.humanize(it).lowercase()}" }, validity).joinToString(" · "),
            color = if (expired) Tone.WARNING.textColor else AppColors.secondaryText)
    }
}

@Composable
fun ShopQuotesScreen(nav: NavHostController) {
    val api = shopApi
    val changes = shopContainer.entityChanges.changes
    var status by remember { mutableStateOf<ShopQuoteStatus?>(null) }
    val model = viewModel(key = "shop.quotes.${status?.wire}") {
        PagedListModel<ShopQuote>({ it.uuid }, { search, page -> api.quotes(search, status, page) }, changes, QUOTE_KIND)
    }
    ShopScaffold(status?.label ?: "Quotes", nav) { modifier ->
        Column(modifier) {
            StatusChips(ShopQuoteStatus.filterable, status, { it.label }) { status = it }
            PagedListScreen(model, "Quote number, email or company", "No quotes", Icons.Default.Description,
                emptyDescription = "Quotes requested from the shop, its assistant or staff appear here.") { quote ->
                GroupedRow(onClick = { nav.navigate(ShopRoutes.quote(quote.uuid)) }, showDivider = false) { ShopQuoteRowContent(quote) }
            }
        }
    }
}

@Composable
fun ShopQuoteDetailScreen(nav: NavHostController, uuid: String) {
    val api = shopApi
    val policy = shopPolicy
    val changes = shopContainer.entityChanges
    val loader = rememberLoader(uuid) { api.quote(uuid) }
    val actions = rememberActions()
    var pending by remember { mutableStateOf<ShopQuoteStatus?>(null) }
    var editingLine by remember { mutableStateOf<ShopLine?>(null) }
    var editingDetails by remember { mutableStateOf(false) }

    fun save(update: ShopQuoteUpdate, onDone: () -> Unit = {}) = actions.run(onDone) {
        val saved = api.updateQuote(uuid, update)
        loader.set(saved)
        changes.post(EntityChange.Updated(QUOTE_KIND, uuid, saved))
    }

    ShopScaffold("Quote", nav) { modifier ->
        when (val state = loader.state) {
            LoadState.Idle, LoadState.Loading -> LoadingState(modifier)
            is LoadState.Failed -> ErrorState(state.error, modifier) { loader.reload() }
            is LoadState.Loaded -> PullToRefreshBox(loader.refreshing, loader::reload, modifier) {
                val quote = state.value
                val expired = quote.isExpired()
                LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                    groupedSection {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(quote.quoteNumber, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                            quote.status.Badge()
                            Text(ShopMoney.format(quote.totalMinor, quote.currency).orEmpty(), style = MaterialTheme.typography.headlineSmall)
                            quote.validUntil?.let {
                                SecondaryText((if (expired) "Expired " else "Valid until ") + Formatters.day(it),
                                    color = if (expired) Tone.WARNING.textColor else AppColors.secondaryText)
                            }
                            SecondaryText(quote.viewedAt?.let { "Customer opened it ${Formatters.relative(it)}" } ?: "Customer hasn't opened it yet")
                        }
                        loader.refreshError?.let { InlineError(it) { loader.reload() } }
                    }
                    val targets = if (policy.canUpdate) quote.status.manualTargets else emptyList()
                    if (targets.isNotEmpty() || actions.error != null) {
                        item {
                            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                targets.forEach { target ->
                                    LargeButton(target.actionTitle, target.icon,
                                        if (target == ShopQuoteStatus.CANCELLED) Tone.DANGER else Tone.PROGRESS,
                                        prominent = false, enabled = !actions.busy) { pending = target }
                                }
                                if (editingLine == null && !editingDetails) actions.error?.let { InlineError(it) }
                            }
                        }
                    }
                    groupedSection("Customer") {
                        DetailRow("Name", quote.customer.name)
                        DetailRow("Company", quote.customer.company)
                        ContactRows(quote.customer.email, quote.customer.phone, quote.customer.formattedAddress)
                        DetailRow("VAT number", quote.customer.vatNumber, showDivider = false)
                    }
                    linesSection(quote.lines, quote.currency, onEdit = if (policy.canUpdate && quote.linesEditable) ({ editingLine = it }) else null)
                    totalsSection(quote.subtotalMinor, quote.vatMinor, quote.shippingMinor, quote.totalMinor, quote.currency)
                    groupedSection("Notes") {
                        DetailRow("For the customer", quote.notes)
                        DetailRow("Internal", quote.internalNotes)
                        if (quote.notes.isNullOrBlank() && quote.internalNotes.isNullOrBlank()) GroupedRow { SecondaryText("No notes") }
                        if (policy.canUpdate) {
                            GroupedRow(onClick = { editingDetails = true }, showDivider = false) {
                                LabelWithIcon("Edit validity, shipping & notes", Icons.Default.Edit)
                            }
                        }
                    }
                    groupedSection("Links") {
                        quote.orderUuid?.let { orderUuid ->
                            GroupedRow(onClick = { nav.navigate(ShopRoutes.order(orderUuid)) }) {
                                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    Text("Order"); Text(quote.orderNumber ?: "View", color = AppColors.secondaryText)
                                }
                            }
                        }
                        DetailRow("Source", quote.source?.let(Formatters::humanize))
                        DetailRow("CRM lead", quote.crmLeadId?.let { "#$it" })
                        DetailRow("Created", Formatters.dateTime(quote.createdAt))
                        quote.publicUrl?.takeIf { it.startsWith("http") }?.let { ShareRow("Share quote link with customer", it, "Quote ${quote.quoteNumber}") }
                    }
                }

                editingLine?.let { line ->
                    QuoteLineSheet(line, quote.currency, canRemove = quote.lines.size > 1, actions, onDismiss = { editingLine = null }) { edited ->
                        // Every line goes back (the server re-prices the lot); null removes this one.
                        val lines = quote.lines.mapNotNull { existing ->
                            if (existing.uuid != line.uuid) ShopLineInput(existing) else edited?.let(::ShopLineInput)
                        }
                        save(ShopQuoteUpdate(lines = lines)) { editingLine = null }
                    }
                }
                if (editingDetails) {
                    QuoteDetailsSheet(quote, actions, onDismiss = { editingDetails = false }) { update ->
                        save(update) { editingDetails = false }
                    }
                }
            }
        }
    }

    pending?.let { target ->
        ConfirmDialog("${target.actionTitle}?", null, target.actionTitle, destructive = target == ShopQuoteStatus.CANCELLED,
            onConfirm = { save(ShopQuoteUpdate(status = target.wire)) }, onDismiss = { pending = null })
    }
}

/** Quantity and an optional unit-price override for one quote line. */
@Composable
private fun QuoteLineSheet(
    line: ShopLine,
    currency: String,
    canRemove: Boolean,
    actions: Actions,
    onDismiss: () -> Unit,
    onSave: (ShopLine?) -> Unit,
) {
    var qty by remember { mutableIntStateOf(line.qty) }
    var overriding by remember { mutableStateOf(line.priceOverrideMinor != null) }
    var priceText by remember { mutableStateOf(ShopMoney.plain(line.priceOverrideMinor ?: line.listUnitPriceMinor ?: line.unitPriceMinor)) }
    var confirmingRemove by remember { mutableStateOf(false) }
    val overrideMinor = if (overriding) ShopMoney.minor(priceText) else null
    val valid = qty >= 1 && (!overriding || overrideMinor != null)
    LaunchedEffect(Unit) { actions.error = null }

    FormSheet("Edit line", saveEnabled = valid, actions = actions, onDismiss = onDismiss,
        onSave = { onSave(line.copy(qty = qty, priceOverrideMinor = overrideMinor)) }) {
        Text(line.productName, style = MaterialTheme.typography.titleMedium)
        if (line.breakdown.isNotEmpty()) SecondaryText(line.breakdown.joinToString(", "))
        Stepper("Quantity", qty, 1..999) { qty = it }
        Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Override unit price", modifier = Modifier.weight(1f))
            Switch(overriding, { overriding = it })
        }
        if (overriding) {
            OutlinedTextField(priceText, { priceText = it }, Modifier.fillMaxWidth(), label = { Text("Unit price ex VAT") },
                singleLine = true, isError = overrideMinor == null, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
        }
        SecondaryText("List price ${ShopMoney.format(line.listUnitPriceMinor ?: line.unitPriceMinor, currency)}. " +
            "Prices are ex VAT; the server re-prices the quote and adds VAT when you save.", Modifier.padding(top = 8.dp))
        if (canRemove) {
            TextButton(onClick = { confirmingRemove = true }, modifier = Modifier.padding(top = 12.dp)) {
                Text("Remove line", color = Tone.DANGER.textColor)
            }
        }
    }
    if (confirmingRemove) {
        ConfirmDialog("Remove ${line.productName}?", null, "Remove line", destructive = true,
            onConfirm = { onSave(null) }, onDismiss = { confirmingRemove = false })
    }
}

@Composable
private fun QuoteDetailsSheet(quote: ShopQuote, actions: Actions, onDismiss: () -> Unit, onSave: (ShopQuoteUpdate) -> Unit) {
    val zone = ZoneId.systemDefault()
    var validUntil by remember { mutableStateOf(quote.validUntil?.atZone(zone)?.toLocalDate() ?: LocalDate.now().plusDays(30)) }
    var shippingText by remember { mutableStateOf(ShopMoney.plain(quote.shippingMinor)) }
    var notes by remember { mutableStateOf(quote.notes.orEmpty()) }
    var internalNotes by remember { mutableStateOf(quote.internalNotes.orEmpty()) }
    var pickingDate by remember { mutableStateOf(false) }
    val shipping = ShopMoney.minor(shippingText)
    LaunchedEffect(Unit) { actions.error = null }

    FormSheet("Quote details", saveEnabled = !quote.linesEditable || shipping != null, actions = actions, onDismiss = onDismiss, onSave = {
        // Only what changed, so an untouched shipping field doesn't make the server re-price.
        val originalDay = quote.validUntil?.atZone(zone)?.toLocalDate()
        onSave(ShopQuoteUpdate(
            validUntil = if (originalDay != validUntil) APIDate.string(validUntil.atTime(23, 59, 59).atZone(zone).toInstant()) else null,
            shippingMinor = shipping?.takeIf { quote.linesEditable && it != quote.shippingMinor },
            notes = notes.takeIf { it != quote.notes.orEmpty() },
            internalNotes = internalNotes.takeIf { it != quote.internalNotes.orEmpty() },
        ))
    }) {
        Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Valid until", modifier = Modifier.weight(1f))
            OutlinedButton(onClick = { pickingDate = true }) {
                Text(Formatters.day(validUntil.atStartOfDay(zone).toInstant()).orEmpty())
            }
        }
        if (quote.linesEditable) {
            OutlinedTextField(shippingText, { shippingText = it }, Modifier.fillMaxWidth(), label = { Text("Shipping ex VAT") },
                singleLine = true, isError = shipping == null, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
        }
        Spacer(Modifier.size(8.dp))
        OutlinedTextField(notes, { notes = it }, Modifier.fillMaxWidth(), label = { Text("Notes for the customer") },
            supportingText = { Text("Shown on the quote") }, minLines = 3)
        OutlinedTextField(internalNotes, { internalNotes = it }, Modifier.fillMaxWidth(), label = { Text("Internal notes") },
            supportingText = { Text("Only staff see these") }, minLines = 3)
    }

    if (pickingDate) {
        val state = rememberDatePickerState(initialSelectedDateMillis = validUntil.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
        DatePickerDialog(
            onDismissRequest = { pickingDate = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { validUntil = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() }
                    pickingDate = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickingDate = false }) { Text("Cancel") } },
        ) { DatePicker(state) }
    }
}

/** − value + with a label; the iOS Stepper. */
@Composable
internal fun Stepper(label: String, value: Int, range: IntRange, step: Int = 1, onChange: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("$label: $value", modifier = Modifier.weight(1f))
        IconButton(onClick = { onChange((value - step).coerceIn(range)) }, enabled = value > range.first) {
            Icon(Icons.Default.Remove, contentDescription = "Decrease $label")
        }
        IconButton(onClick = { onChange((value + step).coerceIn(range)) }, enabled = value < range.last) {
            Icon(Icons.Default.Add, contentDescription = "Increase $label")
        }
    }
}
