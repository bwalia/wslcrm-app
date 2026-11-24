package uk.co.workstation.wslcrm.core.platform

import android.util.Log

/**
 * The one place shared code writes a log line. Android sends it to logcat; the desktop app
 * (`android/desktop`) compiles its own `PlatformLog` in this package instead, so the files that
 * use it are shared with the desktop build unchanged.
 */
object PlatformLog {
    fun d(tag: String, message: String) {
        Log.d(tag, message)
    }

    fun i(tag: String, message: String) {
        Log.i(tag, message)
    }

    fun e(tag: String, message: String) {
        Log.e(tag, message)
    }
}
