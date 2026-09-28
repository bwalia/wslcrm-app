package uk.co.workstation.wslcrm.core.storage

import android.content.SharedPreferences
import java.util.concurrent.ConcurrentHashMap

/**
 * `UserDefaults`: small non-secret preferences (selected workspace, API override, biometric
 * toggle). An interface so JVM tests and the debug stub run against memory.
 */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
    fun getBoolean(key: String): Boolean
    fun putBoolean(key: String, value: Boolean)
    fun remove(key: String)
    fun clear()
}

class SharedPreferencesStore(private val prefs: SharedPreferences) : KeyValueStore {
    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putString(key: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    override fun getBoolean(key: String): Boolean = prefs.getBoolean(key, false)
    override fun putBoolean(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()
    override fun remove(key: String) = prefs.edit().remove(key).apply()
    override fun clear() = prefs.edit().clear().apply()
}

class InMemoryKeyValueStore : KeyValueStore {
    private val values = ConcurrentHashMap<String, Any>()
    override fun getString(key: String): String? = values[key] as? String
    override fun putString(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
    }

    override fun getBoolean(key: String): Boolean = values[key] as? Boolean ?: false
    override fun putBoolean(key: String, value: Boolean) {
        values[key] = value
    }

    override fun remove(key: String) {
        values.remove(key)
    }

    override fun clear() = values.clear()
}
