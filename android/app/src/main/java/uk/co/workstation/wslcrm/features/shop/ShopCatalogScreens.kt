package uk.co.workstation.wslcrm.features.shop

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Category
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Inventory
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
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
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import uk.co.workstation.wslcrm.core.events.EntityChange
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
import uk.co.workstation.wslcrm.designsystem.Tone
import uk.co.workstation.wslcrm.designsystem.groupedSection
import uk.co.workstation.wslcrm.designsystem.trimmedOrNull
import java.math.BigDecimal
import java.math.RoundingMode

internal const val PRODUCT_KIND = "shop.product"

// MARK: - Products

@Composable
fun ShopProductRowContent(product: ShopProductSummary) {
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(product.name, style = MaterialTheme.typography.titleMedium, maxLines = 2)
        SecondaryText(listOfNotNull(product.sku, product.brand, product.category?.name).filter { it.isNotBlank() }.joinToString(" · "), maxLines = 1)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(ShopMoney.format(product.basePriceMinor, product.currency).orEmpty(), fontWeight = FontWeight.SemiBold)
            if (!product.priceVerified) {
                Spacer(Modifier.size(6.dp))
                Icon(Icons.Default.Warning, contentDescription = "Price not verified", tint = Tone.WARNING.textColor, modifier = Modifier.size(16.dp))
            }
            Spacer(Modifier.weight(1f))
            SecondaryText("${product.available} available", color = if (product.lowStock) Tone.DANGER.textColor else AppColors.secondaryText)
        }
    }
}

@Composable
fun ShopProductsScreen(nav: NavHostController) {
    val api = shopApi
    val policy = shopPolicy
    val changes = shopContainer.entityChanges
    var status by remember { mutableStateOf<ShopProductStatus?>(null) }
    var lowStockOnly by remember { mutableStateOf(false) }
    var creating by remember { mutableStateOf(false) }
    val model = viewModel(key = "shop.products.${status?.wire}.$lowStockOnly") {
        PagedListModel<ShopProductSummary>({ it.uuid }, { search, page -> api.products(search, status, lowStockOnly, page) },
            changes.changes, PRODUCT_KIND)
    }
    ShopScaffold("Products", nav, actions = {
        if (policy.canCreate) IconButton(onClick = { creating = true }) { Icon(Icons.Default.Add, contentDescription = "New product") }
    }) { modifier ->
        Column(modifier) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(status == null, onClick = { status = null }, label = { Text("Any status") })
                ShopProductStatus.entries.forEach { s ->
                    FilterChip(status == s, onClick = { status = s }, label = { Text(Formatters.humanize(s.wire)) })
                }
                FilterChip(lowStockOnly, onClick = { lowStockOnly = !lowStockOnly }, label = { Text("Low stock") })
            }
            PagedListScreen(model, "Name, SKU or brand", "No products", Icons.Default.Widgets,
                emptyDescription = if (lowStockOnly) "Nothing is running low." else "Add a product, or import the catalogue from the web dashboard.") { product ->
                GroupedRow(onClick = { nav.navigate(ShopRoutes.product(product.uuid)) }, showDivider = false) { ShopProductRowContent(product) }
            }
        }
    }
    if (creating) {
        ProductFormSheet(null, onDismiss = { creating = false }) { saved ->
            creating = false
            changes.post(EntityChange.Created(PRODUCT_KIND, saved.id, saved.summary))
            nav.navigate(ShopRoutes.product(saved.id))
        }
    }
}

@Composable
fun ShopProductDetailScreen(nav: NavHostController, uuid: String) {
    val api = shopApi
    val policy = shopPolicy
    val changes = shopContainer.entityChanges
    val loader = rememberLoader(uuid) { api.product(uuid) to runCatching { api.movements(uuid, 20) }.getOrDefault(emptyList()) }
    val actions = rememberActions()
    var editing by remember { mutableStateOf(false) }
    var adjusting by remember { mutableStateOf<ShopStockTarget?>(null) }
    var confirmingDelete by remember { mutableStateOf(false) }
    var archivedNotice by remember { mutableStateOf(false) }

    fun publish(product: ShopProduct) {
        loader.value?.let { loader.set(product to it.second) }
        changes.post(EntityChange.Updated(PRODUCT_KIND, uuid, product.summary))
    }

    ShopScaffold("Product", nav, actions = {
        if (policy.canUpdate && loader.value != null) TextButton(onClick = { editing = true }) { Text("Edit") }
    }) { modifier ->
        when (val state = loader.state) {
            LoadState.Idle, LoadState.Loading -> LoadingState(modifier)
            is LoadState.Failed -> ErrorState(state.error, modifier) { loader.reload() }
            is LoadState.Loaded -> PullToRefreshBox(loader.refreshing, loader::reload, modifier) {
                val (product, movements) = state.value
                val s = product.summary
                LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                    groupedSection {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(s.name, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                            SecondaryText(listOfNotNull(s.sku, s.brand).filter { it.isNotBlank() }.joinToString(" · "))
                            ShopProductStatusBadge(s.status)
                            product.shortDescription?.trimmedOrNull?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                        }
                        (loader.refreshError ?: actions.error)?.let { InlineError(it) }
                    }
                    groupedSection("Price") {
                        DetailRow("Base price (ex VAT)", ShopMoney.format(s.basePriceMinor, s.currency))
                        s.fromPriceMinor?.takeIf { it != s.basePriceMinor }?.let { DetailRow("From (configured)", ShopMoney.format(it, s.currency)) }
                        DetailRow("VAT", "${BigDecimal.valueOf(product.vatRate * 100).setScale(1, RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()}%")
                        DetailRow("Pricing", Formatters.humanize(s.priceMode))
                        GroupedRow {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(if (s.priceVerified) Icons.Default.Verified else Icons.Default.Warning, contentDescription = null,
                                    tint = if (s.priceVerified) Tone.SUCCESS.textColor else Tone.WARNING.textColor)
                                Spacer(Modifier.size(12.dp))
                                Text("Price verified", modifier = Modifier.weight(1f))
                                Switch(s.priceVerified, enabled = policy.canUpdate && !actions.busy, onCheckedChange = { verified ->
                                    actions.run { publish(api.updateProduct(uuid, ShopProductBody(priceVerified = verified))) }
                                })
                            }
                        }
                        GroupedRow(onClick = { nav.navigate(ShopRoutes.marketProduct(s.uuid, s.name)) }, showDivider = false) {
                            LabelWithIcon("Market prices", Icons.AutoMirrored.Filled.ShowChart)
                        }
                    }
                    groupedSection("Stock") {
                        StockFigures(s.stockQty, s.held, s.available, s.lowStockThreshold, s.lowStock)
                        DetailRow("Lead time", "${product.leadTimeDays} day${if (product.leadTimeDays == 1) "" else "s"}")
                        DetailRow("Backorders", if (product.allowBackorder) "Allowed" else "Not allowed")
                        if (policy.canUpdate) {
                            GroupedRow(onClick = { adjusting = ShopStockTarget(false, s.uuid, s.name, s.stockQty) }, showDivider = false) {
                                LabelWithIcon("Adjust stock", Icons.Default.SwapVert)
                            }
                        }
                    }
                    val tracked = product.trackedOptions
                    if (tracked.isNotEmpty()) {
                        groupedSection("Option stock", footer = if (policy.canUpdate) "Tap an option to adjust its stock." else null) {
                            tracked.forEachIndexed { index, item ->
                                val option = item.option
                                GroupedRow(
                                    onClick = if (policy.canUpdate && option.uuid != null) ({
                                        adjusting = ShopStockTarget(true, option.uuid, "${item.group.name}: ${option.name}",
                                            option.stockQty ?: option.available ?: 0)
                                    }) else null,
                                    showDivider = index < tracked.lastIndex,
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Column(Modifier.weight(1f)) {
                                            Text(option.name)
                                            SecondaryText(listOfNotNull(item.group.name, option.componentName?.let { "uses $it" }).joinToString(" · "))
                                        }
                                        Text("${option.available ?: option.stockQty ?: 0}", fontWeight = FontWeight.SemiBold)
                                    }
                                }
                            }
                        }
                    }
                    if (product.optionGroups.isNotEmpty() || product.rules.isNotEmpty()) {
                        groupedSection("Configuration", footer = "Option groups and rules are edited in the web dashboard.") {
                            product.optionGroups.forEach { group ->
                                GroupedRow {
                                    Column {
                                        Text(group.name, fontWeight = FontWeight.SemiBold)
                                        SecondaryText("${group.options.count { it.isActive }} options · " +
                                            (if (group.selection == "multi") "pick several" else "pick one") + if (group.required) " · required" else "")
                                    }
                                }
                            }
                            if (product.rules.isNotEmpty()) DetailRow("Compatibility rules", "${product.rules.count { it.isActive }} active", showDivider = false)
                        }
                    }
                    if (product.specs.isNotEmpty()) {
                        groupedSection("Specifications") {
                            product.specs.forEachIndexed { index, (key, value) ->
                                DetailRow(Formatters.humanize(key), value, showDivider = index < product.specs.lastIndex)
                            }
                        }
                    }
                    if (movements.isNotEmpty()) {
                        groupedSection("Recent stock movements") {
                            movements.take(10).forEachIndexed { index, m -> GroupedRow(showDivider = index < 9 && index < movements.lastIndex) { MovementContent(m) } }
                        }
                    }
                    groupedSection {
                        DetailRow("Category", s.category?.name)
                        DetailRow("Type", Formatters.humanize(s.productType))
                        DetailRow("Featured", if (s.isFeatured) "Yes" else "No")
                        DetailRow("Tags", product.tags.takeIf { it.isNotEmpty() }?.joinToString(", "))
                        DetailRow("Updated", Formatters.dateTime(product.updatedAt), showDivider = false)
                    }
                    if (policy.canDelete) {
                        groupedSection(footer = "Products on orders, quotes or carts are archived instead, so their history stays intact.") {
                            GroupedRow(onClick = { confirmingDelete = true }, showDivider = false) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Default.Delete, contentDescription = null, tint = Tone.DANGER.textColor)
                                    Spacer(Modifier.size(12.dp))
                                    Text("Delete product", color = Tone.DANGER.textColor)
                                }
                            }
                        }
                    }
                }

                if (editing) ProductFormSheet(product, onDismiss = { editing = false }) { saved ->
                    editing = false
                    publish(saved)
                }
                adjusting?.let { target ->
                    StockAdjustSheet(target, onDismiss = { adjusting = null }) {
                        adjusting = null
                        loader.reload()
                    }
                }
            }
        }
    }

    if (confirmingDelete) {
        ConfirmDialog("Delete product?", "Products on orders, quotes or carts are archived instead.", "Delete", destructive = true,
            onConfirm = {
                actions.run {
                    if (api.deleteProduct(uuid)) {
                        archivedNotice = true
                        loader.reload()
                    } else {
                        changes.post(EntityChange.Deleted(PRODUCT_KIND, uuid))
                        nav.popBackStack()
                    }
                }
            },
            onDismiss = { confirmingDelete = false })
    }
    if (archivedNotice) {
        AlertDialog(onDismissRequest = { archivedNotice = false }, title = { Text("Archived") },
            text = { Text("This product is referenced by orders, quotes or carts, so it was archived rather than deleted.") },
            confirmButton = { TextButton(onClick = { archivedNotice = false }) { Text("OK") } })
    }
}

/** A dropdown over a fixed set of wire values. */
@Composable
internal fun Picker(label: String, value: String, options: List<Pair<String, String>>, onChange: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded, { expanded = it }, Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        OutlinedTextField(options.firstOrNull { it.first == value }?.second ?: value, {}, readOnly = true, label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable))
        ExposedDropdownMenu(expanded, { expanded = false }) {
            options.forEach { (wire, text) -> DropdownMenuItem(text = { Text(text) }, onClick = { onChange(wire); expanded = false }) }
        }
    }
}

@Composable
internal fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, modifier = Modifier.weight(1f))
        Switch(checked, onChange)
    }
}

/**
 * Create a product, or edit the fields that make sense on a phone. Option groups and rules are
 * never sent, so the server keeps whatever the web editor set up.
 */
@Composable
private fun ProductFormSheet(product: ShopProduct?, onDismiss: () -> Unit, onSaved: (ShopProduct) -> Unit) {
    val api = shopApi
    val actions = rememberActions()
    val s = product?.summary
    var sku by remember { mutableStateOf(s?.sku.orEmpty()) }
    var name by remember { mutableStateOf(s?.name.orEmpty()) }
    var brand by remember { mutableStateOf(s?.brand.orEmpty()) }
    var shortDescription by remember { mutableStateOf(product?.shortDescription.orEmpty()) }
    var productType by remember { mutableStateOf(s?.productType ?: ShopProductType.WORKSTATION.wire) }
    var priceMode by remember { mutableStateOf(s?.priceMode ?: ShopPriceMode.FIXED.wire) }
    var status by remember { mutableStateOf(s?.status ?: ShopProductStatus.DRAFT.wire) }
    var priceText by remember { mutableStateOf(s?.let { ShopMoney.plain(it.basePriceMinor) }.orEmpty()) }
    var vatPercent by remember { mutableIntStateOf(((product?.vatRate ?: 0.2) * 100).toInt()) }
    var openingStock by remember { mutableIntStateOf(0) }
    var lowStockAt by remember { mutableIntStateOf(s?.lowStockThreshold ?: 2) }
    var leadTime by remember { mutableIntStateOf(product?.leadTimeDays ?: 10) }
    var backorder by remember { mutableStateOf(product?.allowBackorder ?: true) }
    var featured by remember { mutableStateOf(s?.isFeatured ?: false) }
    var verified by remember { mutableStateOf(s?.priceVerified ?: false) }
    var categoryUuid by remember { mutableStateOf(s?.category?.uuid.orEmpty()) }
    var categories by remember { mutableStateOf<List<ShopCategory>>(emptyList()) }
    LaunchedEffect(Unit) { categories = runCatching { api.categories() }.getOrDefault(emptyList()) }

    val isNew = product == null
    val price = ShopMoney.minor(priceText)
    val valid = name.isNotBlank() && (!isNew || sku.isNotBlank()) && price != null

    FormSheet(if (isNew) "New product" else "Edit product", saveEnabled = valid, actions = actions, onDismiss = onDismiss, onSave = {
        val body = ShopProductBody(
            sku = if (isNew) sku.trim() else null, name = name.trim(), brand = brand.trim(), productType = productType,
            priceMode = priceMode, status = status, shortDescription = shortDescription.trim(), basePriceMinor = price,
            vatRate = vatPercent / 100.0, stockQty = if (isNew) openingStock else null, lowStockThreshold = lowStockAt,
            leadTimeDays = leadTime, allowBackorder = backorder, priceVerified = verified, isFeatured = featured,
            categoryUuid = categoryUuid,
        )
        actions.run { onSaved(if (product == null) api.createProduct(body) else api.updateProduct(product.id, body)) }
    }) {
        if (isNew) {
            OutlinedTextField(sku, { sku = it }, Modifier.fillMaxWidth(), label = { Text("SKU") }, singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters))
        }
        OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Name") }, singleLine = true)
        OutlinedTextField(brand, { brand = it }, Modifier.fillMaxWidth(), label = { Text("Brand") }, singleLine = true)
        OutlinedTextField(shortDescription, { shortDescription = it }, Modifier.fillMaxWidth(), label = { Text("Short description") }, minLines = 2)
        Picker("Type", productType, ShopProductType.entries.map { it.wire to Formatters.humanize(it.wire) }) { productType = it }
        Picker("Pricing", priceMode, ShopPriceMode.entries.map { it.wire to Formatters.humanize(it.wire) }) { priceMode = it }
        Picker("Status", status, ShopProductStatus.entries.map { it.wire to Formatters.humanize(it.wire) }) { status = it }
        Picker("Category", categoryUuid, listOf("" to "None") + categories.map { it.uuid to it.name }) { categoryUuid = it }
        OutlinedTextField(priceText, { priceText = it }, Modifier.fillMaxWidth(), label = { Text("Base price ex VAT") }, singleLine = true,
            isError = priceText.isNotEmpty() && price == null, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
        Stepper("VAT %", vatPercent, 0..100, step = 5) { vatPercent = it }
        SwitchRow("Price verified", verified) { verified = it }
        SecondaryText("Unverified prices are flagged to customers and the shop assistant.")
        if (isNew) Stepper("Opening stock", openingStock, 0..100_000) { openingStock = it }
        Stepper("Low-stock alert at", lowStockAt, 0..10_000) { lowStockAt = it }
        Stepper("Lead time (days)", leadTime, 0..365) { leadTime = it }
        SwitchRow("Allow backorders", backorder) { backorder = it }
        SwitchRow("Featured", featured) { featured = it }
    }
}

// MARK: - Categories

@Composable
fun ShopCategoriesScreen(nav: NavHostController) {
    val api = shopApi
    val policy = shopPolicy
    val loader = rememberLoader(Unit) { api.categories().sortedWith(compareBy({ it.sortOrder }, { it.name })) }
    val actions = rememberActions()
    var editing by remember { mutableStateOf<Pair<Boolean, ShopCategory?>?>(null) }
    var deleting by remember { mutableStateOf<ShopCategory?>(null) }

    ShopScaffold("Categories", nav, actions = {
        if (policy.canCreate) IconButton(onClick = { editing = true to null }) { Icon(Icons.Default.Add, contentDescription = "New category") }
    }) { modifier ->
        when (val state = loader.state) {
            LoadState.Idle, LoadState.Loading -> LoadingState(modifier)
            is LoadState.Failed -> ErrorState(state.error, modifier) { loader.reload() }
            is LoadState.Loaded -> PullToRefreshBox(loader.refreshing, loader::reload, modifier) {
                if (state.value.isEmpty()) {
                    EmptyState("No categories", Icons.Default.Category, description = "Group products so customers can browse them.")
                } else {
                    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                        actions.error?.let { item { InlineError(it) } }
                        groupedSection(footer = if (policy.canUpdate) "Tap a category to edit it." else null) {
                            state.value.forEachIndexed { index, category ->
                                GroupedRow(onClick = if (policy.canUpdate) ({ editing = true to category }) else null,
                                    showDivider = index < state.value.lastIndex) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Column(Modifier.weight(1f)) {
                                            Text(category.name, fontWeight = FontWeight.SemiBold)
                                            SecondaryText(listOfNotNull("/${category.slug}", if (category.isActive) null else "hidden").joinToString(" · "))
                                        }
                                        category.productCount?.let { SecondaryText("$it") }
                                        if (policy.canDelete) IconButton(onClick = { deleting = category }) {
                                            Icon(Icons.Default.Delete, contentDescription = "Delete ${category.name}", tint = Tone.DANGER.textColor)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    editing?.let { (_, category) ->
        CategoryFormSheet(category, onDismiss = { editing = null }) {
            editing = null
            loader.reload()
        }
    }
    deleting?.let { category ->
        ConfirmDialog("Delete ${category.name}?", "Products in it stay, without a category.", "Delete", destructive = true,
            onConfirm = { actions.run { api.deleteCategory(category.uuid); loader.reload() } }, onDismiss = { deleting = null })
    }
}

@Composable
private fun CategoryFormSheet(category: ShopCategory?, onDismiss: () -> Unit, onSaved: () -> Unit) {
    val api = shopApi
    val actions = rememberActions()
    var name by remember { mutableStateOf(category?.name.orEmpty()) }
    var slug by remember { mutableStateOf(category?.slug.orEmpty()) }
    var description by remember { mutableStateOf(category?.description.orEmpty()) }
    var sortOrder by remember { mutableIntStateOf(category?.sortOrder ?: 0) }
    var active by remember { mutableStateOf(category?.isActive ?: true) }
    FormSheet(if (category == null) "New category" else "Edit category", saveEnabled = name.isNotBlank(), actions = actions,
        onDismiss = onDismiss, onSave = {
            val body = ShopCategoryBody(name.trim(), slug.trimmedOrNull, description.trimmedOrNull, sortOrder, active)
            actions.run(onSaved) { if (category == null) api.createCategory(body) else api.updateCategory(category.uuid, body) }
        }) {
        OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Name") }, singleLine = true)
        OutlinedTextField(slug, { slug = it }, Modifier.fillMaxWidth(), label = { Text("Slug (optional)") }, singleLine = true)
        OutlinedTextField(description, { description = it }, Modifier.fillMaxWidth(), label = { Text("Description") }, minLines = 2)
        Stepper("Sort order", sortOrder, -100..1000) { sortOrder = it }
        SwitchRow("Visible in the shop", active) { active = it }
    }
}

// MARK: - Stock

@Composable
internal fun StockFigures(stock: Int, held: Int, available: Int, threshold: Int, isLow: Boolean) {
    Row(Modifier.fillMaxWidth().padding(16.dp)) {
        listOf("On hand" to stock, "Held" to held, "Available" to available).forEach { (title, value) ->
            Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}) {
                SecondaryText(title)
                Text("$value", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold,
                    color = if (title == "Available" && isLow) Tone.DANGER.textColor else MaterialTheme.colorScheme.onSurface)
            }
        }
    }
    if (isLow) {
        Row(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Warning, contentDescription = null, tint = Tone.DANGER.textColor, modifier = Modifier.size(16.dp))
            Spacer(Modifier.size(6.dp))
            SecondaryText("At or below the low-stock alert ($threshold)", color = Tone.DANGER.textColor)
        }
    }
}

@Composable
fun ShopStockRowContent(row: ShopStockRow) {
    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(row.title, fontWeight = FontWeight.SemiBold, maxLines = 2)
            SecondaryText(listOfNotNull(row.sku, row.groupName, row.held.takeIf { it > 0 }?.let { "$it held" }).joinToString(" · "))
        }
        Column(horizontalAlignment = Alignment.End) {
            Text("${row.available}", fontWeight = FontWeight.Bold, color = if (row.isLow) Tone.DANGER.textColor else MaterialTheme.colorScheme.onSurface)
            // A negative threshold means "never alert" (services, built-to-order).
            SecondaryText(if (row.lowStockThreshold < 0) "no stock alert" else "alert at ${row.lowStockThreshold}")
        }
    }
}

@Composable
internal fun MovementContent(movement: ShopStockMovement) {
    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(Formatters.humanize(movement.reason))
            SecondaryText(listOfNotNull(movement.optionName ?: movement.productName, movement.note?.trimmedOrNull,
                Formatters.dateTime(movement.createdAt)).joinToString(" · "))
        }
        Text(if (movement.delta > 0) "+${movement.delta}" else "${movement.delta}", fontWeight = FontWeight.Bold,
            color = if (movement.delta > 0) Tone.SUCCESS.textColor else Tone.DANGER.textColor)
    }
}

@Composable
fun ShopStockScreen(nav: NavHostController, initialLowOnly: Boolean) {
    val api = shopApi
    val policy = shopPolicy
    var lowOnly by remember { mutableStateOf(initialLowOnly) }
    var search by remember { mutableStateOf("") }
    var adjusting by remember { mutableStateOf<ShopStockTarget?>(null) }
    var showingMovements by remember { mutableStateOf(false) }
    val loader = rememberLoader(lowOnly) { api.stock(lowOnly) }

    ShopScaffold("Stock", nav, actions = {
        IconButton(onClick = { showingMovements = true }) { Icon(Icons.Default.History, contentDescription = "Stock movements") }
    }) { modifier ->
        Column(modifier) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                listOf(false to "All stock", true to "Low stock").forEachIndexed { index, (value, label) ->
                    SegmentedButton(lowOnly == value, { lowOnly = value }, SegmentedButtonDefaults.itemShape(index, 2)) { Text(label) }
                }
            }
            SearchField(search, "Product, option or SKU") { search = it }
            when (val state = loader.state) {
                LoadState.Idle, LoadState.Loading -> LoadingState()
                is LoadState.Failed -> ErrorState(state.error) { loader.reload() }
                is LoadState.Loaded -> PullToRefreshBox(loader.refreshing, loader::reload, Modifier.fillMaxSize()) {
                    val term = search.trim().lowercase()
                    val rows = if (term.isEmpty()) state.value else state.value.filter { "${it.title} ${it.sku.orEmpty()}".lowercase().contains(term) }
                    if (rows.isEmpty()) {
                        EmptyState(if (lowOnly) "Nothing is running low" else "No stock", Icons.Default.Inventory)
                    } else {
                        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                            groupedSection(footer = if (policy.canUpdate) "Tap a row to adjust its stock." else null) {
                                rows.forEachIndexed { index, row ->
                                    GroupedRow(onClick = if (policy.canUpdate) ({
                                        adjusting = ShopStockTarget(row.isOption, row.uuid, row.title, row.stockQty)
                                    }) else null, showDivider = index < rows.lastIndex) { ShopStockRowContent(row) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    adjusting?.let { target ->
        StockAdjustSheet(target, onDismiss = { adjusting = null }) {
            adjusting = null
            loader.reload()
        }
    }
    if (showingMovements) MovementsDialog { showingMovements = false }
}

@Composable
private fun MovementsDialog(onDismiss: () -> Unit) {
    val api = shopApi
    val loader = rememberLoader(Unit) { api.movements(limit = 100) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Stock movements") }, confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        text = {
            when (val state = loader.state) {
                LoadState.Idle, LoadState.Loading -> LoadingState()
                is LoadState.Failed -> InlineError(state.error) { loader.reload() }
                is LoadState.Loaded -> if (state.value.isEmpty()) Text("No movements yet") else LazyColumn {
                    items(state.value, key = { it.uuid }) { MovementContent(it); Spacer(Modifier.size(10.dp)) }
                }
            }
        })
}

@Composable
internal fun StockAdjustSheet(target: ShopStockTarget, onDismiss: () -> Unit, onSaved: () -> Unit) {
    val api = shopApi
    val actions = rememberActions()
    var adding by remember { mutableStateOf(true) }
    var amount by remember { mutableIntStateOf(1) }
    var reason by remember { mutableStateOf(ShopStockReason.RESTOCK) }
    var note by remember { mutableStateOf("") }
    val delta = if (adding) amount else -amount

    FormSheet("Adjust stock", saveEnabled = true, actions = actions, onDismiss = onDismiss, onSave = {
        actions.run(onSaved) { api.adjustStock(target, ShopStockAdjust(delta, reason.wire, note.trimmedOrNull)) }
    }) {
        Text(target.name, style = MaterialTheme.typography.titleMedium)
        SecondaryText("On hand now: ${target.current}")
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
            listOf(true to "Add", false to "Remove").forEachIndexed { index, (value, label) ->
                SegmentedButton(adding == value, {
                    adding = value
                    reason = if (value) ShopStockReason.RESTOCK else ShopStockReason.ADJUSTMENT
                }, SegmentedButtonDefaults.itemShape(index, 2)) { Text(label) }
            }
        }
        Stepper(if (adding) "Add" else "Remove", amount, 1..10_000) { amount = it }
        Picker("Reason", reason.wire, ShopStockReason.entries.map { it.wire to Formatters.humanize(it.wire) }) { wire ->
            reason = ShopStockReason.entries.first { it.wire == wire }
        }
        OutlinedTextField(note, { note = it }, Modifier.fillMaxWidth(), label = { Text("Note (optional)") }, singleLine = true)
        SecondaryText("On hand becomes ${target.current + delta}. Stock held for checkouts isn't affected.", Modifier.padding(top = 8.dp))
    }
}
