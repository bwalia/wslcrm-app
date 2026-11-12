package uk.co.workstation.wslcrm.features.menu

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import uk.co.workstation.wslcrm.app.APIEndpoint
import uk.co.workstation.wslcrm.core.auth.CurrentUser
import uk.co.workstation.wslcrm.core.auth.Workspace
import java.net.URI

/** A web dashboard page opened inside the app (`/dashboard/chat`). */
data class WebPageRoute(val title: String, val path: String)

/** The web dashboard that goes with an API server. Mirrors `DashboardURL` in WebSession.swift. */
object DashboardUrl {
    /**
     * OpsAPI serves its dashboard next to the API with `-ui` added to the first part of the name
     * (`int-opsapi.workstation.co.uk` -> `int-opsapi-ui.workstation.co.uk`), and on port 8039 for a
     * stack on this machine. null when the API isn't named that way: there's no page to open.
     */
    fun forApi(api: String): String? {
        val host = runCatching { URI(api).host?.lowercase() }.getOrNull()?.takeIf { it.isNotEmpty() } ?: return null
        if (APIEndpoint.isLocalHost(api)) return "http://$host:8039"
        val labels = host.split('.').toMutableList()
        if (labels.size < 2 || !labels[0].endsWith("opsapi")) return null
        labels[0] = labels[0] + "-ui"
        return "https://" + labels.joinToString(".")
    }

    /** `scheme://host[:port]`, as `window.location.origin` reports it. */
    fun origin(url: String): String? {
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase() ?: return null
        val defaultPort = if (scheme == "https") 443 else 80
        return if (uri.port != -1 && uri.port != defaultPort) "$scheme://$host:${uri.port}" else "$scheme://$host"
    }
}

/** What a web page needs to open signed in as this person, in this workspace. */
data class WebSession(
    val dashboard: String,
    val accessToken: String,
    val user: CurrentUser,
    val workspace: Workspace,
) {
    val origin: String get() = DashboardUrl.origin(dashboard).orEmpty()

    fun url(route: WebPageRoute): String = origin + route.path

    /**
     * A tiny page loaded on the dashboard's own origin (`loadDataWithBaseURL`): it writes the sign-in
     * and workspace the dashboard reads from its storage, plus the in-app flag (no top bar, sidebar or
     * footer), then opens [target]. It does nothing on any other origin.
     */
    fun bootstrapHtml(target: String): String {
        val namespace = buildJsonObject {
            put("uuid", workspace.uuid)
            put("name", workspace.name)
            workspace.internalId?.let { put("id", it) }
            workspace.slug?.let { put("slug", it) }
        }
        val person = buildJsonObject {
            put("uuid", user.uuid)
            put("email", user.email)
            put("username", user.username ?: user.email)
            put("first_name", user.firstName)
            put("last_name", user.lastName)
        }
        return """
            <!doctype html><meta charset="utf-8"><title></title>
            <script>
            (function () {
              if (window.location.origin !== ${json(JsonPrimitive(origin))}) { return; }
              try {
                var token = ${json(JsonPrimitive(accessToken))}, user = ${json(person)}, ns = ${json(namespace)};
                localStorage.setItem('auth_token', token);
                localStorage.setItem('auth_user', JSON.stringify(user));
                localStorage.setItem('auth-storage', JSON.stringify({ state: { token: token, user: user, isAuthenticated: true }, version: 0 }));
                localStorage.setItem('current_namespace', JSON.stringify(ns));
                localStorage.setItem('namespace-storage', JSON.stringify({ state: { currentNamespace: ns }, version: 0 }));
                localStorage.removeItem('menu-storage');
                localStorage.setItem('opsapi-embed', 'app');
              } catch (e) {}
              window.location.replace(${json(JsonPrimitive(target))});
            })();
            </script>
        """.trimIndent()
    }

    companion object {
        /**
         * A JSON literal that is also safe inside an HTML `<script>`: `<` and the two JavaScript line
         * separators are escaped, so a value can't close the script tag or break the line.
         */
        fun json(value: JsonElement): String = value.toString()
            .replace("<", "\\u003c")
            .replace(" ", "\\u2028")
            .replace(" ", "\\u2029")
    }
}

/**
 * Which addresses the in-app web page may load. Only the dashboard itself loads inside the app;
 * anything else opens outside (browser, mail, phone), never with the person's session.
 */
enum class WebNavigation {
    ALLOW,

    /** The dashboard sent the page to its sign-in screen: the app signs it back in. */
    SIGN_IN_AGAIN,
    OPEN_OUTSIDE,
    BLOCK;

    companion object {
        fun decide(url: String?, dashboard: String, isMainFrame: Boolean): WebNavigation {
            val uri = url?.let { runCatching { URI(it) }.getOrNull() } ?: return BLOCK
            val scheme = uri.scheme?.lowercase() ?: return BLOCK
            if (scheme in setOf("about", "blob", "data")) return ALLOW
            if (!isMainFrame) {
                return if (scheme == "https" || (scheme == "http" && APIEndpoint.isLocalHost(url))) ALLOW else BLOCK
            }
            if (DashboardUrl.origin(url) == DashboardUrl.origin(dashboard)) {
                return if (isSignInPage(uri.path.orEmpty())) SIGN_IN_AGAIN else ALLOW
            }
            return if (scheme in setOf("http", "https", "mailto", "tel", "sms")) OPEN_OUTSIDE else BLOCK
        }

        fun isSignInPage(path: String): Boolean = path == "/login" || path.startsWith("/login/")
    }
}
