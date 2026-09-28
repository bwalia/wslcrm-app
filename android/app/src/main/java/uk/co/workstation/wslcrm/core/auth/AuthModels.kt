package uk.co.workstation.wslcrm.core.auth

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import uk.co.workstation.wslcrm.core.networking.JsonDecodable
import uk.co.workstation.wslcrm.core.networking.LossyList
import uk.co.workstation.wslcrm.core.networking.OpsJson
import uk.co.workstation.wslcrm.core.networking.decodeObject
import java.time.Instant

/** The signed-in user (`user` in `/auth/2fa/verify` and `/auth/me`). */
data class CurrentUser(
    val uuid: String,
    val email: String,
    val username: String? = null,
    val firstName: String,
    val lastName: String,
    /** Platform (global) roles, e.g. `administrative`. Not namespace roles. */
    val platformRoles: List<String> = emptyList(),
) {
    val displayName: String
        get() = "$firstName $lastName".trim().ifEmpty { email }

    val initials: String
        get() {
            val letters = listOfNotNull(firstName.firstOrNull(), lastName.firstOrNull())
            return if (letters.isEmpty()) email.take(1).uppercase() else letters.joinToString("").uppercase()
        }

    val isPlatformAdmin: Boolean get() = "administrative" in platformRoles

    companion object : JsonDecodable<CurrentUser> {
        private val role = JsonDecodable { json -> decodeObject(json) { string("roleName") ?: string("name") } }

        override fun decode(json: JsonElement): CurrentUser = decodeObject(json) {
            CurrentUser(
                uuid = requireString("uuid"),
                email = string("email").orEmpty(),
                username = string("username"),
                firstName = string("firstName").orEmpty(),
                lastName = string("lastName").orEmpty(),
                platformRoles = if (has("platformRoles")) stringList("platformRoles")
                else lossyList("roles", role).filterNotNull(),
            )
        }
    }
}

/** A namespace (tenant) the user belongs to. Addressed by `uuid` in `X-Namespace-Id`. */
data class Workspace(
    val uuid: String,
    /** Numeric namespace id — needed only to scope endpoints that ignore `X-Namespace-Id`. */
    val internalId: Int? = null,
    val name: String,
    val slug: String? = null,
    val logoUrl: String? = null,
    val isOwner: Boolean = false,
) {
    val id: String get() = uuid

    companion object : JsonDecodable<Workspace> {
        override fun decode(json: JsonElement): Workspace = decodeObject(json) {
            Workspace(
                uuid = requireString("uuid"),
                internalId = flexibleInt("id"),
                name = string("name").orEmpty(),
                slug = string("slug"),
                logoUrl = string("logoUrl"),
                isOwner = flexibleBool("isOwner") ?: false,
            )
        }
    }
}

/** Pending second factor after a successful password check. */
data class TwoFactorChallenge(val sessionToken: String, val email: String?, val startedAt: Instant) {
    val expiresAt: Instant get() = startedAt.plusSeconds(LIFETIME_SECONDS)

    companion object {
        /** The session token expires five minutes after login; resending does not extend it. */
        const val LIFETIME_SECONDS = 300L
    }
}

// MARK: - Wire types

/** `POST /auth/login` (form-encoded) -> always the 2FA branch. */
data class LoginResponse(
    /** `requires_2fa` — the key rule turns the digit-led segment into `2Fa`, as in Swift. */
    val requires2Fa: Boolean?,
    val sessionToken: String?,
    val email: String?,
    val message: String?,
    /** Present only if a deployment ever disables mandatory 2FA. */
    val token: String?,
    val refreshToken: String?,
) {
    companion object : JsonDecodable<LoginResponse> {
        override fun decode(json: JsonElement): LoginResponse = decodeObject(json) {
            LoginResponse(bool("requires2Fa"), string("sessionToken"), string("email"), string("message"), string("token"), string("refreshToken"))
        }
    }
}

/** `POST /auth/2fa/verify` -> tokens, user and memberships. */
data class VerifyTwoFactorResponse(
    val user: CurrentUser,
    val token: String,
    val refreshToken: String?,
    val hasPin: Boolean?,
    val namespaces: List<Workspace>,
    val currentNamespace: Workspace?,
) {
    companion object : JsonDecodable<VerifyTwoFactorResponse> {
        override fun decode(json: JsonElement): VerifyTwoFactorResponse = decodeObject(json) {
            VerifyTwoFactorResponse(
                user = require("user", CurrentUser),
                token = requireString("token"),
                refreshToken = string("refreshToken"),
                hasPin = flexibleBool("hasPin"),
                namespaces = lossyList("namespaces", Workspace),
                currentNamespace = optional("currentNamespace", Workspace),
            )
        }
    }
}

/** `GET /auth/me` -> `{ user, namespaces, current_namespace }` (no envelope). */
data class MeResponse(val user: CurrentUser, val namespaces: List<Workspace>, val currentNamespace: Workspace?) {
    companion object : JsonDecodable<MeResponse> {
        override fun decode(json: JsonElement): MeResponse = decodeObject(json) {
            MeResponse(require("user", CurrentUser), lossyList("namespaces", Workspace), optional("currentNamespace", Workspace))
        }
    }
}

/** `POST /api/v2/user/namespaces/:uuid/switch` -> a JWT scoped to that namespace. */
data class SwitchNamespaceResponse(val token: String?) {
    companion object : JsonDecodable<SwitchNamespaceResponse> {
        override fun decode(json: JsonElement) = decodeObject(json) { SwitchNamespaceResponse(string("token")) }
    }
}

/**
 * `{ module: [actions] }`, tolerant of `[]` (empty tables encode as arrays) and of a JSON-encoded
 * string (role permissions are stored as TEXT). Module keys are dictionary keys: never converted.
 */
data class PermissionGrants(val grants: Map<String, Set<String>>) {
    companion object : JsonDecodable<PermissionGrants> {
        private val actions = LossyList(uk.co.workstation.wslcrm.core.networking.Decoders.string)

        override fun decode(json: JsonElement): PermissionGrants = when {
            json is JsonObject -> PermissionGrants(json.mapValues { (_, value) -> actions.decode(value).toSet() })
            json is JsonPrimitive && json.isString -> runCatching {
                val parsed = OpsJson.parse(json.content) as JsonObject
                PermissionGrants(parsed.mapValues { (_, value) -> actions.decode(value).toSet() })
            }.getOrDefault(PermissionGrants(emptyMap()))
            else -> PermissionGrants(emptyMap())
        }
    }
}

/** `GET /api/v2/user/menu` — backend-driven navigation and the caller's permissions. */
data class MenuResponse(
    val menu: List<MenuItem>,
    val namespace: MenuNamespace?,
    val permissions: PermissionGrants,
    val isAdmin: Boolean,
) {
    data class MenuItem(val key: String, val name: String?, val module: String?, val priority: Int?) {
        companion object : JsonDecodable<MenuItem> {
            override fun decode(json: JsonElement) = decodeObject(json) {
                MenuItem(requireString("key"), string("name"), string("module"), flexibleInt("priority"))
            }
        }
    }

    data class MenuNamespace(val uuid: String?, val isOwner: Boolean?) {
        companion object : JsonDecodable<MenuNamespace> {
            override fun decode(json: JsonElement) = decodeObject(json) { MenuNamespace(string("uuid"), flexibleBool("isOwner")) }
        }
    }

    companion object : JsonDecodable<MenuResponse> {
        override fun decode(json: JsonElement): MenuResponse = decodeObject(json) {
            MenuResponse(
                menu = lossyList("menu", MenuItem),
                namespace = optional("namespace", MenuNamespace),
                permissions = optional("permissions", PermissionGrants) ?: PermissionGrants(emptyMap()),
                isAdmin = flexibleBool("isAdmin") ?: false,
            )
        }
    }
}
