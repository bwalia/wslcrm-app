package uk.co.workstation.wslcrm.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color

/**
 * The desktop copy of Android's `designsystem/Theme.kt`: the same scheme, with the house brand's
 * colours written in (Android reads them from `R.color.brand_*`, which a JVM app doesn't have).
 * Keep the two in step; the shared Components.kt reads [AppColors].
 */
object BrandColors {
    val primary = Color(0xFF005499)
    val onPrimary = Color(0xFFFFFFFF)
    val secondary = Color(0xFF0072CB)
}

@Composable
fun WSLCRMTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val scheme = if (darkTheme) {
        darkColorScheme(
            primary = BrandColors.primary,
            onPrimary = BrandColors.onPrimary,
            secondary = BrandColors.secondary,
            background = Color(0xFF000000),
            surface = Color(0xFF1C1C1E),
            surfaceContainer = Color(0xFF1C1C1E),
            surfaceContainerLow = Color(0xFF1C1C1E),
            surfaceContainerHigh = Color(0xFF2C2C2E),
            surfaceVariant = Color(0xFF2C2C2E),
            onSurfaceVariant = Color(0xFFC7C7CC),
            outlineVariant = Color(0xFF38383A),
        )
    } else {
        lightColorScheme(
            primary = BrandColors.primary,
            onPrimary = BrandColors.onPrimary,
            secondary = BrandColors.secondary,
            background = Color(0xFFF2F2F7),
            surface = Color(0xFFFFFFFF),
            surfaceContainer = Color(0xFFFFFFFF),
            surfaceContainerLow = Color(0xFFFFFFFF),
            surfaceContainerHigh = Color(0xFFF2F2F7),
            surfaceVariant = Color(0xFFE5E5EA),
            onSurfaceVariant = Color(0xFF4D4D4D),
            outlineVariant = Color(0xFFD1D1D6),
        )
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

/** Colours the Material scheme has no slot for (as Android's AppColors). */
object AppColors {
    val secondaryText: Color
        @Composable @ReadOnlyComposable
        get() = if (isSystemInDarkTheme()) Color(0.78f, 0.78f, 0.78f) else Color(0.30f, 0.30f, 0.30f)

    val groupedBackground: Color
        @Composable @ReadOnlyComposable
        get() = MaterialTheme.colorScheme.background

    val card: Color
        @Composable @ReadOnlyComposable
        get() = MaterialTheme.colorScheme.surface
}
