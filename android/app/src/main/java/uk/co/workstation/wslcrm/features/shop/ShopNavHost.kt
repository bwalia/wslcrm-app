package uk.co.workstation.wslcrm.features.shop

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import uk.co.workstation.wslcrm.app.AppContainer
import uk.co.workstation.wslcrm.app.LocalAppContainer
import uk.co.workstation.wslcrm.core.networking.APIError
import uk.co.workstation.wslcrm.core.networking.asAPIError
import uk.co.workstation.wslcrm.designsystem.AppColors
import uk.co.workstation.wslcrm.designsystem.InlineError
import uk.co.workstation.wslcrm.designsystem.LoadState

/** Routes inside the Shop tab. Detail routes carry ids only; screens fetch what they show. */
object ShopRoutes {
    const val HOME = "shop"
    const val ORDERS = "shop/orders?status={status}"
    const val ORDER = "shop/order/{uuid}"
    const val QUOTES = "shop/quotes"
    const val QUOTE = "shop/quote/{uuid}"
    const val PRODUCTS = "shop/products"
    const val PRODUCT = "shop/product/{uuid}"
    const val CATEGORIES = "shop/categories"
    const val STOCK = "shop/stock?low={low}"
    const val MARKET = "shop/market"
    const val MARKET_PRODUCT = "shop/market/{uuid}?title={title}"
    const val CHATS = "shop/chats"
    const val CHAT = "shop/chat/{uuid}"
    const val KNOWLEDGE = "shop/knowledge"

    fun orders(status: ShopOrderStatus? = null) = "shop/orders?status=${status?.wire.orEmpty()}"
    fun order(uuid: String) = "shop/order/$uuid"
    fun quote(uuid: String) = "shop/quote/$uuid"
    fun product(uuid: String) = "shop/product/$uuid"
    fun stock(lowOnly: Boolean = false) = "shop/stock?low=$lowOnly"
    fun marketProduct(uuid: String, title: String) = "shop/market/$uuid?title=${Uri.encode(title)}"
    fun chat(uuid: String) = "shop/chat/$uuid"
}

/** The Shop tab's own back stack. */
@Composable
fun ShopNavHost() {
    val nav = rememberNavController()
    NavHost(nav, startDestination = ShopRoutes.HOME) {
        composable(ShopRoutes.HOME) { ShopHomeScreen(nav) }
        composable(ShopRoutes.ORDERS, listOf(navArgument("status") { type = NavType.StringType; defaultValue = "" })) { entry ->
            ShopOrdersScreen(nav, ShopOrderStatus.entries.firstOrNull { it.wire == entry.arguments?.getString("status") })
        }
        composable(ShopRoutes.ORDER) { ShopOrderDetailScreen(nav, it.arguments?.getString("uuid").orEmpty()) }
        composable(ShopRoutes.QUOTES) { ShopQuotesScreen(nav) }
        composable(ShopRoutes.QUOTE) { ShopQuoteDetailScreen(nav, it.arguments?.getString("uuid").orEmpty()) }
        composable(ShopRoutes.PRODUCTS) { ShopProductsScreen(nav) }
        composable(ShopRoutes.PRODUCT) { ShopProductDetailScreen(nav, it.arguments?.getString("uuid").orEmpty()) }
        composable(ShopRoutes.CATEGORIES) { ShopCategoriesScreen(nav) }
        composable(ShopRoutes.STOCK, listOf(navArgument("low") { type = NavType.BoolType; defaultValue = false })) {
            ShopStockScreen(nav, it.arguments?.getBoolean("low") ?: false)
        }
        composable(ShopRoutes.MARKET) { ShopMarketScreen(nav) }
        composable(ShopRoutes.MARKET_PRODUCT, listOf(navArgument("title") { type = NavType.StringType; defaultValue = "" })) {
            ShopMarketDetailScreen(nav, it.arguments?.getString("uuid").orEmpty(),
                Uri.decode(it.arguments?.getString("title").orEmpty()))
        }
        composable(ShopRoutes.CHATS) { ShopChatsScreen(nav) }
        composable(ShopRoutes.CHAT) { ShopChatDetailScreen(nav, it.arguments?.getString("uuid").orEmpty()) }
        composable(ShopRoutes.KNOWLEDGE) { ShopKnowledgeScreen(nav) }
    }
}

// MARK: - Screen helpers

/** A shop screen: top bar with back (unless it's the tab's root) and actions, grouped background. */
@Composable
internal fun ShopScaffold(
    title: String,
    nav: NavHostController?,
    actions: @Composable RowScope.() -> Unit = {},
    content: @Composable (Modifier) -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1) },
                navigationIcon = {
                    if (nav != null) IconButton(onClick = { nav.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = actions,
            )
        },
    ) { padding ->
        content(Modifier.fillMaxSize().background(AppColors.groupedBackground).padding(padding))
    }
}

internal val shopContainer: AppContainer @Composable get() = LocalAppContainer.current
internal val shopApi: ShopAPI @Composable get() = LocalAppContainer.current.shop
internal val shopPolicy: ShopPolicy @Composable get() = ShopPolicy(LocalAppContainer.current.session.permissions)

/** One screen's primary content: loads on first show, reloads on demand, keeps the last value on failure. */
internal class Loader<T>(private val scope: CoroutineScope, private val fetch: suspend () -> T) {
    var state by mutableStateOf<LoadState<T>>(LoadState.Idle)
    /** A failure to refresh content that is already on screen. */
    var refreshError by mutableStateOf<APIError?>(null)

    /** True while content already on screen is being re-fetched (pull to refresh). */
    var refreshing by mutableStateOf(false)
        private set

    val value: T? get() = state.value

    fun reload() {
        scope.launch {
            if (state.value == null) state = LoadState.Loading else refreshing = true
            try {
                state = LoadState.Loaded(fetch())
                refreshError = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val error = e.asAPIError
                if (error is APIError.Cancelled) return@launch
                if (state.value == null) state = LoadState.Failed(error) else refreshError = error
            } finally {
                refreshing = false
            }
        }
    }

    fun set(value: T) {
        state = LoadState.Loaded(value)
    }
}

@Composable
internal fun <T> rememberLoader(key: Any?, fetch: suspend () -> T): Loader<T> {
    val scope = rememberCoroutineScope()
    val loader = remember(key) { Loader(scope, fetch) }
    LaunchedEffect(loader) { loader.reload() }
    return loader
}

/** Runs writes for a screen: one at a time, with the last failure kept for display. */
internal class Actions(private val scope: CoroutineScope) {
    var busy by mutableStateOf(false)
    var error by mutableStateOf<APIError?>(null)

    fun run(onSuccess: () -> Unit = {}, action: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                action()
                error = null
                onSuccess()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.asAPIError
            } finally {
                busy = false
            }
        }
    }
}

@Composable
internal fun rememberActions(): Actions {
    val scope = rememberCoroutineScope()
    return remember { Actions(scope) }
}

/** A form in a bottom sheet: title, Cancel / Save, scrolling fields, and the save's error. */
@Composable
internal fun FormSheet(
    title: String,
    saveEnabled: Boolean,
    actions: Actions,
    saveText: String = "Save",
    onDismiss: () -> Unit,
    onSave: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().imePadding().navigationBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f), maxLines = 1)
                TextButton(onClick = onSave, enabled = saveEnabled && !actions.busy) { Text(if (actions.busy) "Saving…" else saveText) }
            }
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp)) {
                actions.error?.let { InlineError(it) }
                content()
                Spacer(Modifier.size(24.dp))
            }
        }
    }
}

/** `remember { mutableStateOf(x) }` keyed on what the form edits. */
@Composable
internal fun <T> rememberField(key: Any?, initial: T): MutableState<T> = remember(key) { mutableStateOf(initial) }
