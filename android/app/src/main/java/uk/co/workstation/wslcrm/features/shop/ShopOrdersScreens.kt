package uk.co.workstation.wslcrm.features.shop

import android.content.Intent
import android.net.Uri
import androidx.core.net.toUri
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import uk.co.workstation.wslcrm.core.events.EntityChange
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

internal const val ORDER_KIND = "shop.order"

@Composable
fun ShopOrderRowContent(order: ShopOrder) {
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(order.orderNumber, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            order.status.Badge()
        }
        Row {
            Text(order.customerName, style = MaterialTheme.typography.titleMedium, maxLines = 1, modifier = Modifier.weight(1f))
            Text(ShopMoney.format(order.totalMinor, order.currency).orEmpty(), style = MaterialTheme.typography.titleMedium)
        }
        val items = order.itemCount.takeIf { it > 0 }?.let { "$it item${if (it == 1) "" else "s"}" }
        SecondaryText(listOfNotNull(items, Formatters.dateTime(order.createdAt)).joinToString(" · "))
    }
}

/** "All" plus one chip per status. */
@Composable
internal fun <S> StatusChips(options: List<S>, selected: S?, label: (S) -> String, onSelect: (S?) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(selected == null, onClick = { onSelect(null) }, label = { Text("All") })
        options.forEach { option -> FilterChip(selected == option, onClick = { onSelect(option) }, label = { Text(label(option)) }) }
    }
}

@Composable
fun ShopOrdersScreen(nav: NavHostController, initialStatus: ShopOrderStatus?) {
    val api = shopApi
    val changes = shopContainer.entityChanges.changes
    var status by remember { mutableStateOf(initialStatus) }
    // A new filter needs a new model: the fetch captures it.
    val model = viewModel(key = "shop.orders.${status?.wire}") {
        PagedListModel<ShopOrder>({ it.uuid }, { search, page -> api.orders(search, status, page) }, changes, ORDER_KIND)
    }
    ShopScaffold(status?.label ?: "Orders", nav) { modifier ->
        Column(modifier) {
            StatusChips(ShopOrderStatus.filterable, status, { it.label }) { status = it }
            PagedListScreen(model, "Order number, email or name", "No orders", Icons.Default.ShoppingCart,
                emptyDescription = if (status == null) "Orders placed on the shop appear here." else "No orders are ${status!!.label.lowercase()}.") { order ->
                GroupedRow(onClick = { nav.navigate(ShopRoutes.order(order.uuid)) }, showDivider = false) { ShopOrderRowContent(order) }
            }
        }
    }
}

@Composable
fun ShopOrderDetailScreen(nav: NavHostController, uuid: String) {
    val api = shopApi
    val policy = shopPolicy
    val changes = shopContainer.entityChanges
    val loader = rememberLoader(uuid) { api.order(uuid) }
    val actions = rememberActions()
    var pending by remember { mutableStateOf<ShopOrderStatus?>(null) }
    var editing by remember { mutableStateOf(false) }

    fun save(update: ShopOrderUpdate, onDone: () -> Unit = {}) = actions.run(onDone) {
        val saved = api.updateOrder(uuid, update)
        loader.set(saved)
        changes.post(EntityChange.Updated(ORDER_KIND, uuid, saved))
    }

    ShopScaffold("Order", nav) { modifier ->
        when (val state = loader.state) {
            LoadState.Idle, LoadState.Loading -> LoadingState(modifier)
            is LoadState.Failed -> ErrorState(state.error, modifier) { loader.reload() }
            is LoadState.Loaded -> PullToRefreshBox(loader.refreshing, loader::reload, modifier) {
                val order = state.value
                LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                    groupedSection {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(order.orderNumber, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                            order.status.Badge()
                            Text(ShopMoney.format(order.totalMinor, order.currency).orEmpty(), style = MaterialTheme.typography.headlineSmall)
                            SecondaryText(listOfNotNull("Placed ${Formatters.dateTime(order.createdAt) ?: "—"}",
                                order.paidAt?.let { "paid ${Formatters.dateTime(it)}" }).joinToString(", "))
                        }
                        loader.refreshError?.let { InlineError(it) { loader.reload() } }
                    }
                    val targets = if (policy.canUpdate) order.status.manualTargets else emptyList()
                    if (targets.isNotEmpty() || actions.error != null) {
                        item {
                            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                targets.forEach { target ->
                                    LargeButton(target.actionTitle, target.icon, if (target.isDestructive) Tone.DANGER else Tone.PROGRESS,
                                        prominent = false, enabled = !actions.busy) { pending = target }
                                }
                                if (order.status == ShopOrderStatus.PENDING_PAYMENT) SecondaryText("Cancelling releases the stock held for this order.")
                                actions.error?.let { InlineError(it) }
                            }
                        }
                    }
                    groupedSection("Customer") {
                        DetailRow("Name", order.customer?.name)
                        DetailRow("Company", order.customer?.company)
                        ContactRows(order.email ?: order.customer?.email, order.customer?.phone,
                            ShopAddress.format(order.shippingAddress) ?: order.customer?.formattedAddress)
                        DetailRow("VAT number", order.customer?.vatNumber, showDivider = false)
                    }
                    linesSection(order.lines, order.currency)
                    totalsSection(order.subtotalMinor, order.vatMinor, order.shippingMinor, order.totalMinor, order.currency)
                    groupedSection("Fulfilment") {
                        val tracking = order.tracking
                        if (tracking != null && !tracking.isEmpty) {
                            DetailRow("Carrier", tracking.carrier)
                            DetailRow("Tracking number", tracking.trackingNumber)
                            tracking.url?.let { LinkRow("Track parcel", Icons.Default.LocationOn, it.toUri()) }
                        } else {
                            GroupedRow { SecondaryText("No tracking yet") }
                        }
                        DetailRow("Internal notes", order.internalNotes)
                        if (policy.canUpdate) {
                            GroupedRow(onClick = { editing = true }, showDivider = false) { LabelWithIcon("Edit tracking & notes", Icons.Default.Edit) }
                        }
                    }
                    groupedSection("Payment") {
                        DetailRow("Stripe mode", order.stripeMode?.let(Formatters::humanize))
                        DetailRow("Payment intent", order.stripePaymentIntentId)
                        val quoteUuid = order.quoteUuid
                        if (quoteUuid != null && order.quoteNumber != null) {
                            GroupedRow(onClick = { nav.navigate(ShopRoutes.quote(quoteUuid)) }) {
                                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    Text("From quote"); Text(order.quoteNumber, color = AppColors.secondaryText)
                                }
                            }
                        }
                        order.publicUrl?.takeIf { it.startsWith("http") }?.let { ShareRow("Share customer's order link", it, "Order ${order.orderNumber}") }
                    }
                }

                if (editing) FulfilmentSheet(order, actions, onDismiss = { editing = false }) { tracking, notes ->
                    save(ShopOrderUpdate(tracking = tracking, internalNotes = notes)) { editing = false }
                }
            }
        }
    }

    pending?.let { target ->
        ConfirmDialog(
            title = "${target.actionTitle}?",
            message = if (target == ShopOrderStatus.REFUNDED) "This records the refund only. Issue the money back in Stripe." else null,
            confirmText = target.actionTitle,
            destructive = target.isDestructive,
            onConfirm = { save(ShopOrderUpdate(status = target.wire)) },
            onDismiss = { pending = null },
        )
    }
}

@Composable
private fun FulfilmentSheet(order: ShopOrder, actions: Actions, onDismiss: () -> Unit, onSave: (ShopTracking, String) -> Unit) {
    var carrier by remember { mutableStateOf(order.tracking?.carrier.orEmpty()) }
    var number by remember { mutableStateOf(order.tracking?.trackingNumber.orEmpty()) }
    var url by remember { mutableStateOf(order.tracking?.url.orEmpty()) }
    var notes by remember { mutableStateOf(order.internalNotes.orEmpty()) }
    LaunchedEffect(Unit) { actions.error = null }
    FormSheet("Fulfilment", saveEnabled = true, actions = actions, onDismiss = onDismiss, onSave = {
        onSave(ShopTracking(carrier.trim().ifEmpty { null }, number.trim().ifEmpty { null }, url.trim().ifEmpty { null }), notes.trim())
    }) {
        OutlinedTextField(carrier, { carrier = it }, Modifier.fillMaxWidth(), label = { Text("Carrier") }, singleLine = true)
        OutlinedTextField(number, { number = it }, Modifier.fillMaxWidth(), label = { Text("Tracking number") }, singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters))
        OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), label = { Text("Tracking link") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        Spacer(Modifier.size(8.dp))
        OutlinedTextField(notes, { notes = it }, Modifier.fillMaxWidth(), label = { Text("Internal notes") },
            supportingText = { Text("Only staff see these") }, minLines = 3)
    }
}

// MARK: - Shared order/quote pieces

@Composable
internal fun ContactRows(email: String?, phone: String?, address: String?) {
    email?.let { LinkRow(it, Icons.Default.Email, "mailto:$it".toUri()) }
    phone?.let { LinkRow(it, Icons.Default.Phone, "tel:${it.filter { c -> c.isDigit() || c == '+' }}".toUri()) }
    address?.let { LinkRow(it, Icons.Default.LocationOn, "geo:0,0?q=${Uri.encode(it)}".toUri()) }
}

@Composable
internal fun LinkRow(text: String, icon: ImageVector, uri: Uri) {
    val context = LocalContext.current
    GroupedRow(onClick = { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri)) } }) {
        LabelWithIcon(text, icon)
    }
}

@Composable
internal fun ShareRow(text: String, link: String, subject: String) {
    val context = LocalContext.current
    GroupedRow(onClick = {
        val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, link).putExtra(Intent.EXTRA_SUBJECT, subject)
        context.startActivity(Intent.createChooser(send, text))
    }, showDivider = false) { LabelWithIcon(text, Icons.Default.Share) }
}

internal fun LazyListScope.linesSection(lines: List<ShopLine>, currency: String, onEdit: ((ShopLine) -> Unit)? = null) {
    groupedSection("Items", footer = if (onEdit != null && lines.isNotEmpty()) "Tap a line to change its quantity or price." else null) {
        if (lines.isEmpty()) GroupedRow(showDivider = false) { SecondaryText("No items") }
        lines.forEachIndexed { index, line ->
            GroupedRow(onClick = onEdit?.let { { it(line) } }, showDivider = index < lines.lastIndex) { ShopLineContent(line, currency) }
        }
    }
}

@Composable
internal fun ShopLineContent(line: ShopLine, currency: String) {
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row {
            Text(line.productName, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text(ShopMoney.format(line.lineSubtotalMinor, currency).orEmpty())
        }
        SecondaryText(listOfNotNull(line.sku, "${line.qty} × ${ShopMoney.format(line.unitPriceMinor, currency)}").joinToString(" · "))
        if (line.breakdown.isNotEmpty()) SecondaryText(line.breakdown.joinToString(", "))
        if (line.priceOverrideMinor != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.LocalOffer, contentDescription = null, tint = Tone.WARNING.textColor, modifier = Modifier.size(14.dp))
                Spacer(Modifier.size(4.dp))
                SecondaryText("Price overridden (list ${ShopMoney.format(line.listUnitPriceMinor, currency) ?: "—"})", color = Tone.WARNING.textColor)
            }
        }
        if (!line.valid) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Warning, contentDescription = null, tint = Tone.DANGER.textColor, modifier = Modifier.size(14.dp))
                Spacer(Modifier.size(4.dp))
                SecondaryText("Configuration breaks a rule", color = Tone.DANGER.textColor)
            }
        }
    }
}

internal fun LazyListScope.totalsSection(subtotal: Long, vat: Long, shipping: Long, total: Long, currency: String) {
    groupedSection("Totals") {
        DetailRow("Subtotal (ex VAT)", ShopMoney.format(subtotal, currency))
        DetailRow("VAT", ShopMoney.format(vat, currency))
        DetailRow("Shipping", ShopMoney.format(shipping, currency))
        DetailRow("Total", ShopMoney.format(total, currency), showDivider = false)
    }
}
