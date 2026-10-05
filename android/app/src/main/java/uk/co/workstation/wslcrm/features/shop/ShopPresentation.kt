package uk.co.workstation.wslcrm.features.shop

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocalShipping
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Verified
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector
import uk.co.workstation.wslcrm.core.permissions.Action
import uk.co.workstation.wslcrm.core.permissions.Module
import uk.co.workstation.wslcrm.core.permissions.PermissionSet
import uk.co.workstation.wslcrm.designsystem.Formatters
import uk.co.workstation.wslcrm.designsystem.StatusBadge
import uk.co.workstation.wslcrm.designsystem.Tone

/** What the signed-in user may do in the shop back office (RBAC module `shop`). */
data class ShopPolicy(val permissions: PermissionSet) {
    val canCreate: Boolean get() = permissions.can(Action.CREATE, Module.SHOP)
    val canUpdate: Boolean get() = permissions.can(Action.UPDATE, Module.SHOP)
    val canDelete: Boolean get() = permissions.can(Action.DELETE, Module.SHOP)
}

// Every status has a label, an icon and a tone, so status is never conveyed by colour alone.

val ShopOrderStatus.label: String
    get() = when (this) {
        ShopOrderStatus.PENDING_PAYMENT -> "Awaiting payment"
        ShopOrderStatus.PAID -> "Paid"
        ShopOrderStatus.PROCESSING -> "Processing"
        ShopOrderStatus.SHIPPED -> "Shipped"
        ShopOrderStatus.DELIVERED -> "Delivered"
        ShopOrderStatus.CANCELLED -> "Cancelled"
        ShopOrderStatus.REFUNDED -> "Refunded"
        ShopOrderStatus.PAYMENT_FAILED -> "Payment failed"
        ShopOrderStatus.UNKNOWN -> "Unknown"
    }

val ShopOrderStatus.icon: ImageVector
    get() = when (this) {
        ShopOrderStatus.PENDING_PAYMENT -> Icons.Default.CreditCard
        ShopOrderStatus.PAID -> Icons.Default.CheckCircle
        ShopOrderStatus.PROCESSING -> Icons.Default.Inventory2
        ShopOrderStatus.SHIPPED -> Icons.Default.LocalShipping
        ShopOrderStatus.DELIVERED -> Icons.Default.Verified
        ShopOrderStatus.CANCELLED -> Icons.Default.Cancel
        ShopOrderStatus.REFUNDED -> Icons.AutoMirrored.Filled.Undo
        ShopOrderStatus.PAYMENT_FAILED -> Icons.Default.Error
        ShopOrderStatus.UNKNOWN -> Icons.Default.HelpOutline
    }

val ShopOrderStatus.tone: Tone
    get() = when (this) {
        ShopOrderStatus.PENDING_PAYMENT, ShopOrderStatus.UNKNOWN -> Tone.NEUTRAL
        ShopOrderStatus.PAID -> Tone.INFO
        ShopOrderStatus.PROCESSING, ShopOrderStatus.SHIPPED -> Tone.PROGRESS
        ShopOrderStatus.DELIVERED -> Tone.SUCCESS
        ShopOrderStatus.REFUNDED -> Tone.WARNING
        ShopOrderStatus.CANCELLED, ShopOrderStatus.PAYMENT_FAILED -> Tone.DANGER
    }

val ShopOrderStatus.actionTitle: String
    get() = when (this) {
        ShopOrderStatus.PROCESSING -> "Start processing"
        ShopOrderStatus.SHIPPED -> "Mark shipped"
        ShopOrderStatus.DELIVERED -> "Mark delivered"
        ShopOrderStatus.CANCELLED -> "Cancel order"
        ShopOrderStatus.REFUNDED -> "Mark refunded"
        else -> "Mark ${label.lowercase()}"
    }

val ShopOrderStatus.isDestructive: Boolean get() = this == ShopOrderStatus.CANCELLED || this == ShopOrderStatus.REFUNDED

@Composable
fun ShopOrderStatus.Badge() = StatusBadge(label, icon, tone)

val ShopQuoteStatus.label: String
    get() = when (this) {
        ShopQuoteStatus.DRAFT -> "Draft"
        ShopQuoteStatus.SENT -> "Sent"
        ShopQuoteStatus.ACCEPTED -> "Accepted"
        ShopQuoteStatus.EXPIRED -> "Expired"
        ShopQuoteStatus.CONVERTED -> "Ordered"
        ShopQuoteStatus.CANCELLED -> "Cancelled"
        ShopQuoteStatus.UNKNOWN -> "Unknown"
    }

val ShopQuoteStatus.icon: ImageVector
    get() = when (this) {
        ShopQuoteStatus.DRAFT -> Icons.Default.Edit
        ShopQuoteStatus.SENT -> Icons.AutoMirrored.Filled.Send
        ShopQuoteStatus.ACCEPTED -> Icons.Default.ThumbUp
        ShopQuoteStatus.EXPIRED -> Icons.Default.Timer
        ShopQuoteStatus.CONVERTED -> Icons.Default.ShoppingCart
        ShopQuoteStatus.CANCELLED -> Icons.Default.Cancel
        ShopQuoteStatus.UNKNOWN -> Icons.Default.HelpOutline
    }

val ShopQuoteStatus.tone: Tone
    get() = when (this) {
        ShopQuoteStatus.DRAFT, ShopQuoteStatus.UNKNOWN -> Tone.NEUTRAL
        ShopQuoteStatus.SENT -> Tone.INFO
        ShopQuoteStatus.ACCEPTED -> Tone.PROGRESS
        ShopQuoteStatus.CONVERTED -> Tone.SUCCESS
        ShopQuoteStatus.EXPIRED -> Tone.WARNING
        ShopQuoteStatus.CANCELLED -> Tone.DANGER
    }

val ShopQuoteStatus.actionTitle: String
    get() = when (this) {
        ShopQuoteStatus.DRAFT -> "Move back to draft"
        ShopQuoteStatus.SENT -> "Mark sent"
        ShopQuoteStatus.ACCEPTED -> "Mark accepted"
        ShopQuoteStatus.EXPIRED -> "Mark expired"
        ShopQuoteStatus.CANCELLED -> "Cancel quote"
        else -> "Mark ${label.lowercase()}"
    }

@Composable
fun ShopQuoteStatus.Badge() = StatusBadge(label, icon, tone)

@Composable
fun ShopProductStatusBadge(raw: String) = when (raw) {
    ShopProductStatus.ACTIVE.wire -> StatusBadge("Active", Icons.Default.CheckCircle, Tone.SUCCESS)
    ShopProductStatus.DRAFT.wire -> StatusBadge("Draft", Icons.Default.Edit, Tone.NEUTRAL)
    ShopProductStatus.ARCHIVED.wire -> StatusBadge("Archived", Icons.Default.Archive, Tone.WARNING)
    else -> StatusBadge(Formatters.humanize(raw), Icons.Default.HelpOutline, Tone.NEUTRAL)
}

/** `{ released: 2, marked_paid: 1 }` -> "Marked paid: 1 · Released: 2". */
fun describeResult(result: kotlinx.serialization.json.JsonElement): String {
    val obj = result as? kotlinx.serialization.json.JsonObject ?: return "Done."
    val parts = obj.entries.sortedBy { it.key }.mapNotNull { (key, value) ->
        (value as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { "${Formatters.humanize(key)}: $it" }
    }
    return if (parts.isEmpty()) "Nothing needed doing." else parts.joinToString(" · ")
}
