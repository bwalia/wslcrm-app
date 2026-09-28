package uk.co.workstation.wslcrm.designsystem

import uk.co.workstation.wslcrm.core.networking.APIError

/** The loading lifecycle of a screen's primary content (mirrors `LoadState`). */
sealed interface LoadState<out T> {
    data object Idle : LoadState<Nothing>
    data object Loading : LoadState<Nothing>
    data class Loaded<T>(override val value: T) : LoadState<T>
    data class Failed(override val error: APIError) : LoadState<Nothing>

    val value: T? get() = (this as? Loaded<T>)?.value
    val error: APIError? get() = (this as? Failed)?.error
    val isLoading: Boolean get() = this is Loading
}
