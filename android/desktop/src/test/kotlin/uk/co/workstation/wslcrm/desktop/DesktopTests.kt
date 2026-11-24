package uk.co.workstation.wslcrm.desktop

import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import kotlinx.coroutines.runBlocking
import org.jetbrains.skia.EncodedImageFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.workstation.wslcrm.designsystem.WSLCRMTheme
import java.io.File

class DesktopTests {
    @Test
    fun httpsAnywhereButPlainHttpOnlyForThisMachine() {
        assertEquals("https://int-opsapi.workstation.co.uk", DesktopConfig.validate("https://int-opsapi.workstation.co.uk/"))
        assertEquals("http://127.0.0.1:4012", DesktopConfig.validate("http://127.0.0.1:4012"))
        assertEquals("http://localhost:4011", DesktopConfig.validate("http://localhost:4011"))
        val refused = runCatching { DesktopConfig.validate("http://acc-opsapi.workstation.co.uk") }.exceptionOrNull()
        assertTrue(refused is DesktopConfig.InsecureEndpoint)
    }

    /**
     * Draws the sign-in screen off screen (no window, so it runs in CI and needs no screen-recording
     * permission) and saves it for docs/DESKTOP.md and the PR.
     */
    @Test
    fun rendersTheSignInScreen() {
        val session = makeSession("http://127.0.0.1:1")
        runBlocking { session.restore() }
        assertEquals(DesktopSession.Phase.SignedOut, session.phase)

        val scene = ImageComposeScene(width = 1100, height = 780, density = Density(1f)) {
            WSLCRMTheme(darkTheme = false) { RootScreen(session, "Local") }
        }
        scene.render() // first frame lays out; the second draws loaded resources
        val image = scene.render()
        scene.close()
        val png = image.encodeToData(EncodedImageFormat.PNG)!!.bytes
        assertTrue(png.size > 10_000)
        System.getProperty("wslcrm.snapshotDir")?.let { dir ->
            File(dir).mkdirs()
            File(dir, "desktop-compose-signin.png").writeBytes(png)
        }
    }
}
