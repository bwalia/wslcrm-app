package uk.co.workstation.wslcrm.core.events

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Tells list screens that a record changed on a detail screen, so they can patch their rows
 * without reloading. This replaces the Swift `onChange: (Model?) -> Void` closures that a SwiftUI
 * `NavigationLink { Detail(onChange:) }` passes down — Navigation Compose routes carry only ids.
 *
 * Post from the detail screen: `changes.post(EntityChange.Updated("crm.account", account.uuid, account))`;
 * collect in the list's view model and call `PagedListModel.replace` / `remove`.
 */
sealed interface EntityChange {
    val kind: String
    val key: String

    data class Updated(override val kind: String, override val key: String, val value: Any) : EntityChange
    data class Deleted(override val kind: String, override val key: String) : EntityChange
    data class Created(override val kind: String, override val key: String, val value: Any) : EntityChange
}

class EntityChanges {
    private val flow = MutableSharedFlow<EntityChange>(extraBufferCapacity = 32)
    val changes: SharedFlow<EntityChange> = flow.asSharedFlow()

    fun post(change: EntityChange) {
        flow.tryEmit(change)
    }
}
