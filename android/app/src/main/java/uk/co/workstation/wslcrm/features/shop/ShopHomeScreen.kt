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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Category
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.CurrencyPound
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Inventory
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import uk.co.workstation.wslcrm.designsystem.ErrorState
import uk.co.workstation.wslcrm.designsystem.GroupedRow
import uk.co.workstation.wslcrm.designsystem.InlineError
import uk.co.workstation.wslcrm.designsystem.LoadState
import uk.co.workstation.wslcrm.designsystem.LoadingState
import uk.co.workstation.wslcrm.designsystem.Notice
import uk.co.workstation.wslcrm.designsystem.StatTile
import uk.co.workstation.wslcrm.designsystem.Tone
import uk.co.workstation.wslcrm.designsystem.groupedSection
import java.text.NumberFormat

/** The shop back office home: the web dashboard's KPIs, what needs doing, and the way into each area. */
@Composable
fun ShopHomeScreen(nav: NavHostController) {
    val api = shopApi
    val policy = shopPolicy
    val loader = rememberLoader(Unit) { api.dashboard() }
    val actions = rememberActions()
    var notice by remember { mutableStateOf<String?>(null) }

    ShopScaffold("Shop", nav = null, actions = {
        if (policy.canUpdate) {
            IconButton(onClick = {
                actions.run {
                    notice = describeResult(api.reconcile())
                    loader.reload()
                }
            }, enabled = !actions.busy, modifier = Modifier.testTag("shop.reconcile")) {
                if (actions.busy) CircularProgressIndicator(Modifier.size(20.dp)) else Icon(Icons.Default.Sync, contentDescription = "Reconcile payments")
            }
        }
    }) { modifier ->
        when (val state = loader.state) {
            LoadState.Idle, LoadState.Loading -> LoadingState(modifier)
            is LoadState.Failed -> ErrorState(state.error, modifier) { loader.reload() }
            is LoadState.Loaded -> PullToRefreshBox(loader.refreshing, onRefresh = loader::reload, modifier = modifier) {
                Dashboard(nav, state.value, loader.refreshError ?: actions.error)
            }
        }
    }

    notice?.let { text ->
        AlertDialog(onDismissRequest = { notice = null }, title = { Text("Reconciled") }, text = { Text(text) },
            confirmButton = { TextButton(onClick = { notice = null }) { Text("OK") } })
    }
}

@Composable
private fun Dashboard(nav: NavHostController, kpis: ShopKPIs, error: uk.co.workstation.wslcrm.core.networking.APIError?) {
    val money = { minor: Long -> ShopMoney.format(minor, kpis.currency) ?: "—" }
    val percent = NumberFormat.getPercentInstance().apply { maximumFractionDigits = 1 }
    val alerts = alerts(kpis)

    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        error?.let { item { InlineError(it) } }
        if (alerts.isNotEmpty()) {
            item {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    alerts.forEach { Notice(it, Tone.WARNING, icon = Icons.Default.Warning) }
                }
            }
        }
        item {
            val tiles = listOf(
                Triple("Revenue · 30 days", money(kpis.revenuePaid30dMinor), Icons.Default.CurrencyPound),
                Triple("Orders today", "${kpis.ordersToday}", Icons.Default.ShoppingCart),
                Triple("To fulfil", "${kpis.awaitingFulfilment}", Icons.Default.Inventory2),
                Triple("Orders · 7 days", "${kpis.orders7d}", Icons.Default.CalendarMonth),
                Triple("Open quotes", "${kpis.openQuotes} · ${money(kpis.openQuotesValueMinor)}", Icons.Default.Description),
                Triple("Quote → order", percent.format(kpis.quoteConversionRate), Icons.AutoMirrored.Filled.ArrowForward),
                Triple("Low stock", "${kpis.lowStockCount}", Icons.Default.Warning),
                Triple("Chats · 7 days", "${kpis.chats7d}", Icons.Default.Chat),
            )
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                tiles.chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        pair.forEach { (title, value, icon) -> StatTile(title, value, icon, Modifier.weight(1f)) }
                        if (pair.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }

        if (kpis.awaitingFulfilment > 0 || kpis.lowStock.isNotEmpty()) {
            groupedSection("Needs attention") {
                if (kpis.awaitingFulfilment > 0) {
                    val n = kpis.awaitingFulfilment
                    GroupedRow(onClick = { nav.navigate(ShopRoutes.orders(ShopOrderStatus.PAID)) }) {
                        LabelWithIcon("$n paid order${if (n == 1) "" else "s"} to fulfil", Icons.Default.Inventory2)
                    }
                }
                kpis.lowStock.take(5).forEachIndexed { index, row ->
                    GroupedRow(onClick = { nav.navigate(ShopRoutes.stock(lowOnly = true)) }, showDivider = index < kpis.lowStock.take(5).lastIndex) {
                        ShopStockRowContent(row)
                    }
                }
            }
        }
        if (kpis.latestOrders.isNotEmpty()) {
            groupedSection("Latest orders") {
                kpis.latestOrders.forEachIndexed { index, order ->
                    GroupedRow(onClick = { nav.navigate(ShopRoutes.order(order.uuid)) }, showDivider = index < kpis.latestOrders.lastIndex) {
                        ShopOrderRowContent(order)
                    }
                }
            }
        }
        if (kpis.latestQuotes.isNotEmpty()) {
            groupedSection("Latest quotes") {
                kpis.latestQuotes.forEachIndexed { index, quote ->
                    GroupedRow(onClick = { nav.navigate(ShopRoutes.quote(quote.uuid)) }, showDivider = index < kpis.latestQuotes.lastIndex) {
                        ShopQuoteRowContent(quote)
                    }
                }
            }
        }
        groupedSection("Manage") {
            val links = listOf(
                Triple("Orders", Icons.Default.ShoppingCart, ShopRoutes.orders()),
                Triple("Quotes", Icons.Default.Description, ShopRoutes.QUOTES),
                Triple("Products", Icons.Default.Widgets, ShopRoutes.PRODUCTS),
                Triple("Categories", Icons.Default.Category, ShopRoutes.CATEGORIES),
                Triple("Stock", Icons.Default.Inventory, ShopRoutes.stock()),
                Triple("Market prices", Icons.AutoMirrored.Filled.ShowChart, ShopRoutes.MARKET),
                Triple("Assistant chats", Icons.Default.Chat, ShopRoutes.CHATS),
                Triple("Assistant knowledge", Icons.AutoMirrored.Filled.LibraryBooks, ShopRoutes.KNOWLEDGE),
            )
            links.forEachIndexed { index, (title, icon, route) ->
                Column(Modifier.testTag("shop.link.$title")) {
                    GroupedRow(onClick = { nav.navigate(route) }, showDivider = index < links.lastIndex) { LabelWithIcon(title, icon) }
                }
            }
        }
    }
}

@Composable
internal fun LabelWithIcon(text: String, icon: ImageVector) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null)
        Spacer(Modifier.size(12.dp))
        Text(text)
    }
}

private fun alerts(kpis: ShopKPIs): List<String> = buildList {
    if (!kpis.paymentsEnabled) add("Card payments are off: the server has no Stripe key.")
    else if (!kpis.webhookConfigured) add("Stripe webhook secret is missing, so paid orders won't confirm on their own.")
    if (kpis.pendingPayment > 0) add("${kpis.pendingPayment} order${if (kpis.pendingPayment == 1) " is" else "s are"} waiting on payment.")
    if (kpis.unverifiedPrices > 0) {
        add("${kpis.unverifiedPrices} active product${if (kpis.unverifiedPrices == 1) " has" else "s have"} an unverified price.")
    }
}
