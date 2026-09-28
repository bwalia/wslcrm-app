package uk.co.workstation.wslcrm.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color

/**
 * Semantic colours (mirrors `Tone`). Every use is paired with an icon and text, never colour alone.
 * The values are the iOS ones, so contrast characteristics carry over.
 */
enum class Tone(
    private val light: Color,
    private val dark: Color,
    private val solidLight: Color,
    private val solidDark: Color,
    private val textLight: Color,
    private val textDark: Color,
) {
    NEUTRAL(
        light = Color(0xFF8A8A8E), dark = Color(0xFF98989F),
        solidLight = Color(0.26f, 0.26f, 0.26f), solidDark = Color(0.32f, 0.32f, 0.32f),
        textLight = Color(0.28f, 0.28f, 0.28f), textDark = Color(0.84f, 0.84f, 0.84f),
    ),
    INFO(
        light = Color(0xFF007AFF), dark = Color(0xFF0A84FF),
        solidLight = Color(0.00f, 0.31f, 0.72f), solidDark = Color(0.04f, 0.36f, 0.80f),
        textLight = Color(0.00f, 0.31f, 0.72f), textDark = Color(0.45f, 0.72f, 1.00f),
    ),
    PROGRESS(
        light = Color(0xFF5856D6), dark = Color(0xFF5E5CE6),
        solidLight = Color(0.25f, 0.18f, 0.69f), solidDark = Color(0.31f, 0.24f, 0.78f),
        textLight = Color(0.25f, 0.18f, 0.69f), textDark = Color(0.70f, 0.67f, 1.00f),
    ),
    SUCCESS(
        light = Color(0xFF34C759), dark = Color(0xFF30D158),
        solidLight = Color(0.02f, 0.39f, 0.18f), solidDark = Color(0.07f, 0.47f, 0.24f),
        textLight = Color(0.02f, 0.39f, 0.18f), textDark = Color(0.44f, 0.85f, 0.55f),
    ),
    WARNING(
        light = Color(0xFFFF9500), dark = Color(0xFFFF9F0A),
        solidLight = Color(0.45f, 0.28f, 0.00f), solidDark = Color(0.53f, 0.33f, 0.00f),
        textLight = Color(0.45f, 0.28f, 0.00f), textDark = Color(1.00f, 0.78f, 0.38f),
    ),
    DANGER(
        light = Color(0xFFFF3B30), dark = Color(0xFFFF453A),
        solidLight = Color(0.61f, 0.07f, 0.07f), solidDark = Color(0.70f, 0.10f, 0.10f),
        textLight = Color(0.61f, 0.07f, 0.07f), textDark = Color(1.00f, 0.58f, 0.55f),
    ),
    ;

    /** Fills, borders and glyphs. Use [textColor] for anything a person has to read. */
    val color: Color
        @Composable @ReadOnlyComposable
        get() = if (isSystemInDarkTheme()) dark else light

    /** Fill for a solid button or chip with white text on top: 4.5:1 in both appearances. */
    val solidColor: Color
        @Composable @ReadOnlyComposable
        get() = if (isSystemInDarkTheme()) solidDark else solidLight

    /** The readable version of [color]: at least 4.5:1 against this tone's tinted card. */
    val textColor: Color
        @Composable @ReadOnlyComposable
        get() = if (isSystemInDarkTheme()) textDark else textLight
}
