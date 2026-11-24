import java.net.URI
import org.jetbrains.compose.desktop.application.dsl.TargetFormat

// The WSLCRM desktop app for Windows (and macOS/Linux), built with Compose Multiplatform on the
// JVM. It is native UI drawn by Compose (Skia) -- not a web view and not the web dashboard.
//
// Code sharing: the platform-free Kotlin in app/src/main/java (networking, auth models, API
// clients, permissions, menu, shop and project models) is compiled into this module directly,
// file by file (see `shared` below). Android-only pieces (Keystore, SharedPreferences, logcat,
// biometrics, WebView) stay in app/; this module supplies desktop versions of the seams the shared
// files need: core/platform/PlatformLog.kt, designsystem/Theme.kt (Android's reads colours from
// R) and the token store.
//
// The long-term shape is a Kotlin Multiplatform `shared` module with expect/actual; see
// docs/DESKTOP.md. This keeps the Android app untouched while the desktop app proves out.
//
//   ./gradlew :desktop:run                             run it (point it at an API with -Pwslcrm.desktopApiBaseUrl)
//   ./gradlew :desktop:test                            unit tests, plus a rendered sign-in screenshot
//   ./gradlew :desktop:packageDistributionForCurrentOS .msi on Windows, .dmg on macOS, .deb on Linux

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.compose.multiplatform)
}

/** Files from app/src/main/java that build on any JVM. Add to this list as more is made platform-free. */
val shared = listOf(
    "uk/co/workstation/wslcrm/core/networking/**",
    "uk/co/workstation/wslcrm/core/auth/AuthAPI.kt",
    "uk/co/workstation/wslcrm/core/auth/AuthModels.kt",
    "uk/co/workstation/wslcrm/core/auth/AuthTokens.kt",
    "uk/co/workstation/wslcrm/core/offline/PendingMutation.kt",
    "uk/co/workstation/wslcrm/core/permissions/**",
    "uk/co/workstation/wslcrm/core/events/**",
    "uk/co/workstation/wslcrm/designsystem/Components.kt",
    "uk/co/workstation/wslcrm/designsystem/LoadState.kt",
    "uk/co/workstation/wslcrm/designsystem/Tone.kt",
    "uk/co/workstation/wslcrm/features/projects/KanbanAPI.kt",
    "uk/co/workstation/wslcrm/features/projects/KanbanModels.kt",
    "uk/co/workstation/wslcrm/features/projects/TaskAgenda.kt",
)

// Copied (not moved) into build/ so the Android app's layout is unchanged and a stale copy can't
// be edited by mistake: edit the file in app/, the next build picks it up.
val syncSharedSources by tasks.registering(Sync::class) {
    from("../app/src/main/java") { include(shared) }
    into(layout.buildDirectory.dir("generated/shared/kotlin"))
}

sourceSets {
    main {
        kotlin.srcDir(syncSharedSources)
    }
}

/** -P property, then environment variable. The default is the integration API (https). */
fun setting(property: String, env: String): String? =
    (findProperty(property) as String?)?.takeIf { it.isNotBlank() } ?: System.getenv(env)?.takeIf { it.isNotBlank() }

val desktopApiBaseUrl = setting("wslcrm.desktopApiBaseUrl", "WSLCRM_DESKTOP_API_BASE_URL") ?: "https://int-opsapi.workstation.co.uk"
// The same rule as iOS's "Validate API base URL" phase and Android's validateProdApiBaseUrl: https,
// or plain http only for a stack on this machine. Checked when the build is configured.
run {
    val host = runCatching { URI(desktopApiBaseUrl).host }.getOrNull()
    val ok = desktopApiBaseUrl.startsWith("https://") ||
        (desktopApiBaseUrl.startsWith("http://") && host in setOf("127.0.0.1", "localhost"))
    if (!ok) throw GradleException("wslcrm.desktopApiBaseUrl must start with https:// (got '$desktopApiBaseUrl').")
}
val desktopVersion = setting("wslcrm.versionName", "WSLCRM_VERSION_NAME") ?: "1.0.0"

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(libs.kotlinx.coroutines.swing)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    // Windows Credential Manager / macOS Keychain / Linux Secret Service for the JWT pair.
    implementation(libs.java.keyring)

    testImplementation(libs.junit)
    testImplementation(compose.desktop.uiTestJUnit4)
}

compose.desktop {
    application {
        mainClass = "uk.co.workstation.wslcrm.desktop.MainKt"
        jvmArgs += listOf("-Dwslcrm.apiBaseUrl=$desktopApiBaseUrl")
        nativeDistributions {
            targetFormats(TargetFormat.Msi, TargetFormat.Dmg, TargetFormat.Deb)
            packageName = "WSLCRM"
            packageVersion = desktopVersion
            vendor = "Workstation"
            description = "Workstation AI-native CRM"
            copyright = "Copyright Workstation"
            // java.net.http / TLS, and java.naming for OkHttp's DNS on some JDKs.
            modules("java.naming", "jdk.crypto.ec")
            windows {
                // A fixed upgrade code lets a newer MSI replace an older install.
                upgradeUuid = "6b1c3e5e-4a3e-4d5c-9b0e-8f2f1d7a9c41"
                menuGroup = "Workstation"
                perUserInstall = true
                shortcut = true
                iconFile.set(project.file("icons/wslcrm.ico"))
            }
            macOS {
                bundleID = "uk.co.workstation.wslcrm.desktop"
                iconFile.set(project.file("icons/wslcrm.icns"))
            }
            linux {
                iconFile.set(project.file("icons/wslcrm.png"))
            }
        }
    }
}

tasks.test {
    // The rendered screenshot lands next to the Mac build's, in the repo's build/desktop.
    systemProperty("wslcrm.snapshotDir", rootProject.file("../build/desktop").absolutePath)
}
