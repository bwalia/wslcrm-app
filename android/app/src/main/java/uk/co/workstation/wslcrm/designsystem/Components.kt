package uk.co.workstation.wslcrm.designsystem

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import uk.co.workstation.wslcrm.core.networking.APIError

// Shared building blocks (mirrors DesignSystem/Components.swift): status pills, stat tiles, grouped
// cards, detail rows and the loading / empty / error states. Status is never conveyed by colour alone.

/** A status pill: icon + label + tinted background. */
@Composable
fun StatusBadge(text: String, icon: ImageVector, tone: Tone, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.clearAndSetSemantics { contentDescription = "Status: $text" },
        shape = RoundedCornerShape(50),
        color = tone.color.copy(alpha = 0.14f),
        border = BorderStroke(1.dp, tone.color.copy(alpha = 0.35f)),
    ) {
        Row(Modifier.padding(horizontal = 10.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = tone.textColor, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(4.dp))
            Text(text, color = tone.textColor, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, maxLines = 2)
        }
    }
}

/** A KPI tile on a dashboard. */
@Composable
fun StatTile(title: String, value: String, icon: ImageVector, modifier: Modifier = Modifier) {
    Surface(modifier.semantics(mergeDescendants = true) {}, shape = RoundedCornerShape(12.dp), color = AppColors.card) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, contentDescription = null, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(4.dp))
                Text(title, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.size(6.dp))
            Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** An iOS-style grouped section: optional header, a card of rows, optional footer. */
fun LazyListScope.groupedSection(
    title: String? = null,
    footer: String? = null,
    key: Any? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    item(key = key) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            if (title != null) {
                Text(
                    title.uppercase(), style = MaterialTheme.typography.labelMedium, color = AppColors.secondaryText,
                    modifier = Modifier.padding(start = 16.dp, bottom = 6.dp).semantics { heading() },
                )
            }
            Surface(shape = RoundedCornerShape(12.dp), color = AppColors.card) {
                Column(Modifier.fillMaxWidth(), content = content)
            }
            if (footer != null) {
                Text(footer, style = MaterialTheme.typography.bodySmall, color = AppColors.secondaryText,
                    modifier = Modifier.padding(start = 16.dp, top = 6.dp, end = 16.dp))
            }
        }
    }
}

/** A row in a grouped card. Clickable rows get a chevron. */
@Composable
fun GroupedRow(onClick: (() -> Unit)? = null, showDivider: Boolean = true, content: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f)) { content() }
        if (onClick != null) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = AppColors.secondaryText)
        }
    }
    if (showDivider) HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
}

/** Label on the left, value on the right. Nothing is drawn for an empty value. */
@Composable
fun DetailRow(label: String, value: String?, showDivider: Boolean = true) {
    if (value.isNullOrBlank()) return
    GroupedRow(showDivider = showDivider) {
        Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, color = AppColors.secondaryText, modifier = Modifier.padding(end = 12.dp))
            Text(value, textAlign = TextAlign.End)
        }
    }
}

@Composable
fun SecondaryText(text: String, modifier: Modifier = Modifier, color: Color = AppColors.secondaryText, maxLines: Int = Int.MAX_VALUE) {
    Text(text, modifier = modifier, style = MaterialTheme.typography.bodySmall, color = color, maxLines = maxLines, overflow = TextOverflow.Ellipsis)
}

/** Large, high-contrast action button (mirrors `.large(tone, prominent:)`). */
@Composable
fun LargeButton(text: String, icon: ImageVector?, tone: Tone, prominent: Boolean = true, enabled: Boolean = true, onClick: () -> Unit) {
    val content: @Composable () -> Unit = {
        if (icon != null) {
            Icon(icon, contentDescription = null)
            Spacer(Modifier.width(8.dp))
        }
        Text(text, fontWeight = FontWeight.SemiBold)
    }
    val modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)
    if (prominent) {
        Button(onClick, modifier, enabled = enabled, shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(containerColor = tone.solidColor, contentColor = Color.White)) { content() }
    } else {
        OutlinedButton(onClick, modifier, enabled = enabled, shape = RoundedCornerShape(14.dp),
            border = BorderStroke(2.dp, tone.textColor),
            colors = ButtonDefaults.outlinedButtonColors(containerColor = tone.color.copy(alpha = 0.12f), contentColor = tone.textColor)) { content() }
    }
}

@Composable
fun LoadingState(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(Modifier.semantics { contentDescription = "Loading" })
    }
}

@Composable
fun EmptyState(title: String, icon: ImageVector, modifier: Modifier = Modifier, description: String? = null) {
    Column(modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(icon, contentDescription = null, tint = AppColors.secondaryText, modifier = Modifier.size(48.dp))
        Spacer(Modifier.size(12.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        if (description != null) {
            Spacer(Modifier.size(6.dp))
            Text(description, style = MaterialTheme.typography.bodyMedium, color = AppColors.secondaryText, textAlign = TextAlign.Center)
        }
    }
}

/** Full-screen error with a retry, for when a screen has nothing to show. */
@Composable
fun ErrorState(error: APIError, modifier: Modifier = Modifier, retry: () -> Unit) {
    Column(modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(if (error.isConnectivityProblem) Icons.Default.WifiOff else Icons.Default.Warning, contentDescription = null,
            tint = Tone.DANGER.textColor, modifier = Modifier.size(48.dp))
        Spacer(Modifier.size(12.dp))
        Text(error.message, style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center)
        Spacer(Modifier.size(16.dp))
        OutlinedButton(onClick = retry) {
            Icon(Icons.Default.Refresh, contentDescription = null)
            Spacer(Modifier.width(6.dp))
            Text("Try again")
        }
    }
}

/** An error shown inside content that is still useful (a failed save, a page that didn't load). */
@Composable
fun InlineError(error: APIError, modifier: Modifier = Modifier, retry: (() -> Unit)? = null) {
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(if (error.isConnectivityProblem) Icons.Default.WifiOff else Icons.Default.Warning, contentDescription = null,
                tint = Tone.DANGER.textColor, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(error.message, style = MaterialTheme.typography.bodyMedium)
        }
        if (retry != null) {
            TextButton(onClick = retry, contentPadding = PaddingValues(horizontal = 0.dp)) { Text("Try again") }
        }
    }
}

/** A notice banner: icon + text on a tinted card. */
@Composable
fun Notice(text: String, tone: Tone, modifier: Modifier = Modifier, icon: ImageVector = Icons.Default.Warning) {
    Row(
        modifier.fillMaxWidth().background(tone.color.copy(alpha = 0.12f), RoundedCornerShape(10.dp)).padding(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = tone.textColor, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, color = tone.textColor, style = MaterialTheme.typography.bodyMedium)
    }
}

/** A yes/no confirmation. */
@Composable
fun ConfirmDialog(
    title: String,
    message: String?,
    confirmText: String,
    destructive: Boolean = false,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = message?.let { { Text(it) } },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }) {
                Text(confirmText, color = if (destructive) Tone.DANGER.textColor else MaterialTheme.colorScheme.primary)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
