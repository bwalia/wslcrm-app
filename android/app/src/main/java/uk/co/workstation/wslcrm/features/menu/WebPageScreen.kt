package uk.co.workstation.wslcrm.features.menu

import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.webkit.CookieManager
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.launch
import uk.co.workstation.wslcrm.core.auth.SessionStore
import uk.co.workstation.wslcrm.core.networking.asAPIError
import uk.co.workstation.wslcrm.designsystem.SecondaryText

/**
 * A web dashboard page inside the app, already signed in as this person in this workspace. Used for
 * every module the app has no screen of its own for, so the phone offers all of the web. Mirrors
 * `Features/Menu/WebPageView.swift`.
 */
@Composable
fun WebPageScreen(session: SessionStore, route: WebPageRoute, onBack: (() -> Unit)? = null) {
    val scope = rememberCoroutineScope()
    var webSession by remember { mutableStateOf<WebSession?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    var reload by remember { mutableIntStateOf(0) }
    // When the page last had to be signed back in: once a minute at most, so a page that keeps
    // refusing can't loop.
    var lastSignIn by remember { mutableLongStateOf(0L) }

    fun start(forceRefresh: Boolean) {
        scope.launch {
            failure = null
            try {
                val fresh = session.webSession(forceRefresh)
                if (fresh == null) failure = "This server has no web dashboard linked to it, so this page can't open in the app."
                webSession = fresh
            } catch (e: Exception) {
                failure = e.asAPIError.message ?: "Couldn't open ${route.title}."
            }
        }
    }

    fun signInAgain() {
        val now = System.currentTimeMillis()
        if (now - lastSignIn < 60_000) {
            failure = "This page keeps asking you to sign in. Try again, or sign out and back in."
            return
        }
        lastSignIn = now
        start(forceRefresh = true)
    }

    LaunchedEffect(route) { start(forceRefresh = false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(route.title, maxLines = 1) },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                    }
                },
                actions = {
                    IconButton(onClick = { reload++ }, enabled = webSession != null, modifier = Modifier.testTag("web.reload")) {
                        Icon(Icons.Default.Refresh, contentDescription = "Reload")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            val current = webSession
            val error = failure
            when {
                error != null -> Column(
                    Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("Couldn't open ${route.title}")
                    SecondaryText(error, Modifier, maxLines = 6)
                    Button(onClick = { start(forceRefresh = true) }, modifier = Modifier.testTag("web.retry")) { Text("Try again") }
                }
                current == null -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                else -> {
                    DashboardWebView(
                        session = current,
                        target = current.url(route),
                        reload = reload,
                        onLoading = { loading = it },
                        onSignInPage = ::signInAgain,
                        onFailed = { failure = it },
                        modifier = Modifier.fillMaxSize().testTag("web.page"),
                    )
                    if (loading) CircularProgressIndicator(Modifier.align(Alignment.Center))
                }
            }
        }
    }
}

/** Throws away everything web pages stored (signed-in state included). Call on sign-out. */
fun clearWebPageData() {
    WebStorage.getInstance().deleteAllData()
    CookieManager.getInstance().removeAllCookies(null)
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun DashboardWebView(
    session: WebSession,
    target: String,
    reload: Int,
    onLoading: (Boolean) -> Unit,
    onSignInPage: () -> Unit,
    onFailed: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    // File inputs (form uploads, chat attachments): the system picker.
    var pendingFiles by remember { mutableStateOf<ValueCallback<Array<Uri>>?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        pendingFiles?.onReceiveValue(uris.toTypedArray())
        pendingFiles = null
    }
    val state = remember { WebState() }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                // Pinch-to-zoom for accessibility; the dashboard itself turns off zoom-on-tap.
                settings.setSupportZoom(true)
                settings.builtInZoomControls = true
                settings.displayZoomControls = false
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                        val url = request.url.toString()
                        return when (WebNavigation.decide(url, state.session?.dashboard.orEmpty(), request.isForMainFrame)) {
                            WebNavigation.ALLOW -> false
                            WebNavigation.SIGN_IN_AGAIN -> { onSignInPage(); true }
                            WebNavigation.OPEN_OUTSIDE -> {
                                runCatching { view.context.startActivity(Intent(Intent.ACTION_VIEW, request.url)) }
                                true
                            }
                            WebNavigation.BLOCK -> true
                        }
                    }

                    // The dashboard also moves to its sign-in screen without a page load (client-side
                    // routing); the visited address still changes.
                    override fun doUpdateVisitedHistory(view: WebView, url: String?, isReload: Boolean) {
                        val path = url?.let { runCatching { Uri.parse(it).path }.getOrNull() }.orEmpty()
                        if (state.loaded && WebNavigation.isSignInPage(path) &&
                            DashboardUrl.origin(url.orEmpty()) == state.session?.origin
                        ) {
                            view.stopLoading()
                            onSignInPage()
                        }
                    }

                    override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) = onLoading(true)

                    override fun onPageFinished(view: WebView, url: String?) {
                        // The bootstrap page (about:blank-like, on the dashboard origin) isn't the page.
                        if (url != null && url.startsWith(state.session?.origin.orEmpty()) && !url.endsWith("/#bootstrap")) {
                            state.loaded = true
                        }
                        onLoading(false)
                    }

                    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                        if (request.isForMainFrame) {
                            onLoading(false)
                            onFailed(error.description?.toString() ?: "The page didn't load.")
                        }
                    }
                }
                webChromeClient = object : WebChromeClient() {
                    override fun onShowFileChooser(
                        webView: WebView,
                        filePathCallback: ValueCallback<Array<Uri>>,
                        fileChooserParams: FileChooserParams,
                    ): Boolean {
                        pendingFiles?.onReceiveValue(null)
                        pendingFiles = filePathCallback
                        val type = fileChooserParams.acceptTypes.firstOrNull { it.isNotBlank() } ?: "*/*"
                        return runCatching { picker.launch(type) }.isSuccess
                    }
                }
            }
        },
        update = { view ->
            if (state.session != session || state.target != target) {
                state.session = session
                state.target = target
                state.loaded = false
                // Write the sign-in on the dashboard's own origin, then open the page.
                view.loadDataWithBaseURL(session.origin + "/#bootstrap", session.bootstrapHtml(target), "text/html", "UTF-8", null)
            } else if (state.reload != reload) {
                state.reload = reload
                view.reload()
            }
        },
    )
}

/** What the WebView was last given (outside Compose state: changing it must not recompose). */
private class WebState {
    var session: WebSession? = null
    var target: String? = null
    var reload = 0
    var loaded = false
}

/** Shown in a tab when the menu item for that tab isn't in this person's menu. */
@Composable
fun NotInMenu(title: String) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        SecondaryText("$title isn't in your menu for this workspace.", Modifier, maxLines = 4)
    }
}
