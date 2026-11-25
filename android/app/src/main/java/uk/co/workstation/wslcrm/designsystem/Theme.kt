package uk.co.workstation.wslcrm.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.colorResource
import uk.co.workstation.wslcrm.R

/**
 * The app theme: Material 3 coloured by the flavour's brand resources (`brand_primary`, …), with
 * iOS's grouped-background look (a tinted page behind white cards).
 */
@Composable
fun WSLCRMTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val primary = colorResource(R.color.brand_primary)
    val onPrimary = colorResource(R.color.brand_on_primary)
    val secondary = colorResource(R.color.brand_secondary)
    val scheme = if (darkTheme) {
        darkColorScheme(
            primary = primary,
            onPrimary = onPrimary,
            secondary = secondary,
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
            primary = primary,
            onPrimary = onPrimary,
            secondary = secondary,
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
    MaterialTheme(colorScheme = scheme, typography = AppTypography, content = content)
}

/** Colours the Material scheme has no slot for. */
object AppColors {
    /**
     * Supporting text. Material's onSurfaceVariant is close, but this matches iOS's `secondaryText`,
     * chosen to pass 4.5:1 on cards in both appearances.
     */
    val secondaryText: Color
        @Composable @ReadOnlyComposable
        get() = if (isSystemInDarkTheme()) Color(0.78f, 0.78f, 0.78f) else Color(0.30f, 0.30f, 0.30f)

    /** The page behind grouped cards (`systemGroupedBackground`). */
    val groupedBackground: Color
        @Composable @ReadOnlyComposable
        get() = MaterialTheme.colorScheme.background

    /** A card on the grouped background (`secondarySystemGroupedBackground`). */
    val card: Color
        @Composable @ReadOnlyComposable
        get() = MaterialTheme.colorScheme.surface
}

/**
 * Material's type scale, a step larger where it was hard to read: body and label text are a point up (supporting
 * text was 12 sp, labels 11), and titles carry more weight, as on iOS.
 */
private fun TextStyle.sized(size: Int, line: Int) = copy(fontSize = size.sp, lineHeight = line.sp)

private val AppTypography: Typography = Typography().run {
    copy(
        headlineMedium = headlineMedium.sized(28, 36),
        headlineSmall = headlineSmall.sized(24, 32),
        titleLarge = titleLarge.sized(22, 28),
        titleMedium = titleMedium.sized(17, 24),
        titleSmall = titleSmall.sized(15, 21),
        bodyLarge = bodyLarge.sized(17, 25),
        bodyMedium = bodyMedium.sized(15, 22),
        bodySmall = bodySmall.sized(14, 20),
        labelLarge = labelLarge.sized(15, 21),
        labelMedium = labelMedium.sized(13, 18),
        labelSmall = labelSmall.sized(12, 16),
    )
}
