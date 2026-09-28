import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// ---------------------------------------------------------------------------------------------
// Environments and brands. These mirror the iOS schemes and Config/*.xcconfig:
//
//   iOS scheme        Android flavour  API                                  Brand
//   WSLCRM-Int        int              https://int-opsapi.workstation.co.uk house (WSLCRM)
//   WSLCRM-DBS-Int    dbsInt           https://int-opsapi.workstation.co.uk DBS Ltd
//   WSLCRM-Local      local            http://10.0.2.2:4011 (emulator host) DBS Ltd
//   WSLCRM-Prod       prod             -Pwslcrm.prodApiBaseUrl (https only) house (WSLCRM)
//
// Values that iOS reads from Info.plist are BuildConfig fields here; see app/AppConfig.kt and
// app/Brand.kt.
// ---------------------------------------------------------------------------------------------

val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

/** -P property, then environment variable, then the git-ignored local.properties. */
fun setting(property: String, env: String): String? =
    (findProperty(property) as String?)?.takeIf { it.isNotBlank() }
        ?: System.getenv(env)?.takeIf { it.isNotBlank() }
        ?: localProperties.getProperty(property)?.takeIf { it.isNotBlank() }

val prodApiBaseUrl: String = setting("wslcrm.prodApiBaseUrl", "WSLCRM_PROD_API_BASE_URL")?.trim().orEmpty()

// Release numbering and signing, supplied by .github/workflows/android_release.yml. Play refuses
// a versionCode it has seen, so CI passes the run number rather than anyone keeping a counter.
val releaseVersionCode: Int = setting("wslcrm.versionCode", "WSLCRM_VERSION_CODE")?.toIntOrNull() ?: 1
val releaseVersionName: String = setting("wslcrm.versionName", "WSLCRM_VERSION_NAME") ?: "1.0.0"

/** The upload keystore, from android/key.properties (CI writes it; never committed). */
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val localApiPort: String = setting("wslcrm.localApiPort", "WSLCRM_LOCAL_API_PORT") ?: "4011"

fun quoted(value: String): String = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

/** Config/Brand-Default.xcconfig and Config/Brand-DBS.xcconfig. */
data class BrandValues(
    val name: String,
    val hasMark: Boolean = false,
    val legalName: String = "",
    val strapline: String = "",
    val address: String = "",
    val phone: String = "",
    val email: String = "",
    val companyNumber: String = "",
    val vatNumber: String = "",
)

val houseBrand = BrandValues(name = "WSLCRM")
val dbsBrand = BrandValues(
    name = "DBS Ltd",
    hasMark = true,
    legalName = "David Blakey Services Limited",
    // The xcconfig writes its separators as `/$()/`, which expands to `//`.
    strapline = "Air Conditioning // Refrigeration // Heating // Electrical // Controls",
    address = "6-8 Colne Way Court, Colne Way, Watford, Hertfordshire WD24 7NE",
    phone = "01923 246381",
    email = "info@dbsservices.co.uk",
    companyNumber = "03806201",
    vatNumber = "GB 743 5371 32",
)

fun com.android.build.api.dsl.ApplicationProductFlavor.environment(apiBaseUrl: String, environmentName: String, brand: BrandValues) {
    buildConfigField("String", "API_BASE_URL", quoted(apiBaseUrl))
    buildConfigField("String", "API_ENVIRONMENT_NAME", quoted(environmentName))
    buildConfigField("String", "BRAND_NAME", quoted(brand.name))
    buildConfigField("boolean", "BRAND_HAS_MARK", brand.hasMark.toString())
    buildConfigField("String", "BRAND_LEGAL_NAME", quoted(brand.legalName))
    buildConfigField("String", "BRAND_STRAPLINE", quoted(brand.strapline))
    buildConfigField("String", "BRAND_ADDRESS", quoted(brand.address))
    buildConfigField("String", "BRAND_PHONE", quoted(brand.phone))
    buildConfigField("String", "BRAND_EMAIL", quoted(brand.email))
    buildConfigField("String", "BRAND_COMPANY_NUMBER", quoted(brand.companyNumber))
    buildConfigField("String", "BRAND_VAT_NUMBER", quoted(brand.vatNumber))
    resValue("string", "app_name", brand.name)
}

android {
    namespace = "uk.co.workstation.wslcrm"
    compileSdk = 35

    defaultConfig {
        applicationId = "uk.co.workstation.wslcrm"
        minSdk = 26
        targetSdk = 35
        versionCode = releaseVersionCode
        versionName = releaseVersionName
    }

    signingConfigs {
        if (keyProperties.getProperty("storeFile") != null) {
            create("upload") {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // Request/response logging (redacted), as iOS Debug builds do.
            buildConfigField("boolean", "NETWORK_LOGGING", "true")
        }
        release {
            buildConfigField("boolean", "NETWORK_LOGGING", "false")
            // Without key.properties a release build is unsigned, and Play refuses it: the
            // release workflow fails before building rather than uploading that.
            signingConfigs.findByName("upload")?.let { signingConfig = it }
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    flavorDimensions += "environment"
    productFlavors {
        create("int") {
            dimension = "environment"
            isDefault = true
            applicationIdSuffix = ".integration"
            environment("https://int-opsapi.workstation.co.uk", "Int", houseBrand)
        }
        create("dbsInt") {
            dimension = "environment"
            applicationIdSuffix = ".dbs"
            environment("https://int-opsapi.workstation.co.uk", "Int", dbsBrand)
        }
        create("local") {
            // 10.0.2.2 is the emulator's alias for the Mac's 127.0.0.1, where the Docker stack
            // listens. The only flavour allowed plain http (src/local/res/xml).
            dimension = "environment"
            applicationIdSuffix = ".local"
            environment("http://10.0.2.2:$localApiPort", "Local", dbsBrand)
        }
        create("prod") {
            dimension = "environment"
            environment(prodApiBaseUrl, "Production", houseBrand)
        }
    }

    sourceSets {
        // White-label resources (launcher icon, brand mark, colours) shared by the flavours
        // that carry each brand.
        getByName("int") { res.srcDir("src/brandHouse/res") }
        getByName("prod") { res.srcDir("src/brandHouse/res") }
        getByName("dbsInt") { res.srcDir("src/brandDbs/res") }
        getByName("local") { res.srcDir("src/brandDbs/res") }
        // The iOS test fixtures are the single source of truth for captured API payloads.
        getByName("test") { resources.srcDir("../../WSLCRMTests/Fixtures") }
    }

    buildFeatures {
        compose = true
        buildConfig = true
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests {
            // android.util.Log and friends return defaults instead of throwing in JVM tests.
            isReturnDefaultValues = true
        }
    }

    lint {
        warningsAsErrors = false
        abortOnError = true
        checkDependencies = false
        // Dependency versions are pinned deliberately in libs.versions.toml (they must build
        // against compileSdk 35); upgrades are a separate, tested change.
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion")
    }
}

kotlin {
    jvmToolchain(17)
    compilerOptions {
        optIn.addAll(
            "kotlinx.serialization.ExperimentalSerializationApi",
            "androidx.compose.material3.ExperimentalMaterial3Api",
        )
    }
}

// iOS has no Release-Local configuration; neither does Android.
androidComponents {
    beforeVariants { variant ->
        if (variant.productFlavors.any { it.second == "local" } && variant.buildType == "release") {
            variant.enable = false
        }
    }
}

// Mirrors the iOS "Validate API base URL" build phase: a prod build fails unless the URL was
// supplied and is https. Other flavours are unaffected.
val validateProdApiBaseUrl by tasks.registering {
    val url = prodApiBaseUrl
    doLast {
        if (url.isEmpty()) {
            throw GradleException(
                "The prod API base URL is empty. Pass -Pwslcrm.prodApiBaseUrl=https://your-host, set " +
                    "WSLCRM_PROD_API_BASE_URL, or add wslcrm.prodApiBaseUrl to local.properties (see android/README.md).",
            )
        }
        if (!url.startsWith("https://")) {
            throw GradleException("The prod API base URL must start with https:// (got '$url').")
        }
    }
}
tasks.configureEach {
    if (name.startsWith("preProd") && name.endsWith("Build")) dependsOn(validateProdApiBaseUrl)
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.fragment.ktx)
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
}
