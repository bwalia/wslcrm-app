package uk.co.workstation.wslcrm.desktop

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import uk.co.workstation.wslcrm.core.auth.AuthAPI
import uk.co.workstation.wslcrm.core.networking.APIClient
import uk.co.workstation.wslcrm.core.networking.NetworkLogger
import uk.co.workstation.wslcrm.designsystem.WSLCRMTheme

/** Builds the shared API client for this machine: the OS credential store, the configured API. */
fun makeSession(apiBaseUrl: String = DesktopConfig.apiBaseUrl): DesktopSession {
    val client = APIClient(
        baseUrl = apiBaseUrl,
        tokenStore = DesktopTokenStore(apiBaseUrl),
        logger = NetworkLogger(isEnabled = System.getProperty("wslcrm.networkLogging") == "true"),
        appVersion = DesktopSession::class.java.`package`?.implementationVersion ?: "desktop",
    )
    return DesktopSession(client, AuthAPI(client))
}

fun main() = application {
    val session = remember { makeSession() }
    LaunchedEffect(Unit) { session.restore() }
    Window(
        onCloseRequest = ::exitApplication,
        title = "WSLCRM",
        icon = painterResource("wslcrm.png"),
        state = rememberWindowState(size = DpSize(1100.dp, 780.dp)),
    ) {
        WSLCRMTheme { RootScreen(session, DesktopConfig.environmentName) }
    }
}
