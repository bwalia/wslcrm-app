package uk.co.workstation.wslcrm.designsystem

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import uk.co.workstation.wslcrm.core.events.EntityChange
import uk.co.workstation.wslcrm.core.networking.APIError
import uk.co.workstation.wslcrm.core.networking.Page
import uk.co.workstation.wslcrm.core.networking.asAPIError

/**
 * Loads pages from any envelope-specific fetcher and exposes list state (mirrors `PagedListModel`).
 * A [ViewModel], so a list keeps its rows and scroll while a detail screen is on top of it.
 *
 * Pass [changes] and [kind] to have rows patched when a detail screen posts an [EntityChange].
 */
class PagedListModel<T>(
    /** A row's stable identity (its uuid). */
    val id: (T) -> String,
    private val fetch: suspend (search: String, page: Int) -> Page<T>,
    changes: SharedFlow<EntityChange>? = null,
    private val kind: String? = null,
) : ViewModel() {
    var search by mutableStateOf("")
        private set
    var items by mutableStateOf<List<T>>(emptyList())
        private set
    var state by mutableStateOf<LoadState<Unit>>(LoadState.Idle)
        private set
    var pageError by mutableStateOf<APIError?>(null)
        private set
    var isLoadingMore by mutableStateOf(false)
        private set
    var isRefreshing by mutableStateOf(false)
        private set
    private var lastPage: Page<T>? = null
    private var loadJob: Job? = null

    val hasMore: Boolean get() = lastPage?.hasMore ?: false
    val total: Int? get() = lastPage?.total

    init {
        if (changes != null && kind != null) {
            viewModelScope.launch {
                changes.collect { change ->
                    if (change.kind != kind) return@collect
                    @Suppress("UNCHECKED_CAST")
                    when (change) {
                        is EntityChange.Updated -> replace(change.value as T)
                        is EntityChange.Deleted -> remove(change.key)
                        is EntityChange.Created -> load()
                    }
                }
            }
        }
    }

    /** Debounced: typing reloads 350 ms after the last keystroke. */
    fun updateSearch(text: String) {
        search = text
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            delay(350)
            loadNow()
        }
    }

    fun load() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch { loadNow() }
    }

    fun refresh() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            isRefreshing = true
            try {
                loadNow()
            } finally {
                isRefreshing = false
            }
        }
    }

    private suspend fun loadNow() {
        if (items.isEmpty()) state = LoadState.Loading
        try {
            val page = fetch(search, 1)
            items = page.items
            lastPage = page
            pageError = null
            state = LoadState.Loaded(Unit)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val error = e.asAPIError
            if (error is APIError.Cancelled) return
            if (items.isEmpty()) state = LoadState.Failed(error) else pageError = error
        }
    }

    fun loadMoreIfNeeded(index: Int) {
        val last = lastPage ?: return
        if (!hasMore || isLoadingMore || index < items.size - 1) return
        isLoadingMore = true
        viewModelScope.launch {
            try {
                val page = fetch(search, last.page + 1)
                val known = items.map(id).toSet()
                items = items + page.items.filter { id(it) !in known }
                lastPage = page
                pageError = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                pageError = e.asAPIError
            } finally {
                isLoadingMore = false
            }
        }
    }

    /** Replaces an item after an edit without reloading everything. */
    fun replace(item: T) {
        val key = id(item)
        items = items.map { if (id(it) == key) item else it }
    }

    fun remove(key: String) {
        items = items.filterNot { id(it) == key }
    }
}

/**
 * Standard list screen: loading -> rows / empty / error, search, pull to refresh, infinite scroll
 * (mirrors `PagedList`). [header] sits above the rows (filters, tiles).
 */
@Composable
fun <T> PagedListScreen(
    model: PagedListModel<T>,
    searchPrompt: String?,
    emptyTitle: String,
    emptyIcon: ImageVector,
    modifier: Modifier = Modifier,
    emptyDescription: String? = null,
    header: (LazyListScope.() -> Unit)? = null,
    row: @Composable (T) -> Unit,
) {
    LaunchedEffect(model) {
        // Fresh data whenever the screen is shown again; rows already loaded stay up meanwhile.
        if (model.items.isEmpty()) model.load() else model.refresh()
    }
    Column(modifier.fillMaxSize()) {
        if (searchPrompt != null) SearchField(model.search, searchPrompt, model::updateSearch)
        PullToRefreshBox(isRefreshing = model.isRefreshing, onRefresh = model::refresh, modifier = Modifier.fillMaxSize()) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
                header?.invoke(this)
                itemsIndexed(model.items, key = { _, item -> model.id(item) }) { index, item ->
                    LaunchedEffect(index, model.items.size) { model.loadMoreIfNeeded(index) }
                    Surface(color = AppColors.card) { Box(Modifier.fillMaxWidth()) { row(item) } }
                    HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
                }
                if (model.isLoadingMore) {
                    item { Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
                }
                model.pageError?.let { error ->
                    item { InlineError(error, retry = { if (model.hasMore) model.loadMoreIfNeeded(model.items.size - 1) else model.load() }) }
                }
            }
            when (val state = model.state) {
                LoadState.Idle, LoadState.Loading -> if (model.items.isEmpty()) LoadingState()
                is LoadState.Failed -> if (model.items.isEmpty()) ErrorState(state.error) { model.load() }
                is LoadState.Loaded -> if (model.items.isEmpty()) {
                    if (model.search.isEmpty()) EmptyState(emptyTitle, emptyIcon, description = emptyDescription)
                    else EmptyState("No results", emptyIcon, description = "Nothing matches “${model.search}”.")
                }
            }
        }
    }
}

/** A search box that sits above a list. */
@Composable
fun SearchField(text: String, prompt: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = text,
        onValueChange = onChange,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        placeholder = { androidx.compose.material3.Text(prompt) },
        leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
        trailingIcon = {
            if (text.isNotEmpty()) IconButton(onClick = { onChange("") }) { Icon(Icons.Default.Clear, contentDescription = "Clear search") }
        },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        shape = MaterialTheme.shapes.large,
    )
}
