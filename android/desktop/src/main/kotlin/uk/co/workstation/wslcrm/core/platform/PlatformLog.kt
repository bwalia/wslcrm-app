package uk.co.workstation.wslcrm.core.platform

/**
 * The desktop side of the logging seam (Android's is in app/, writing to logcat). Lines go to
 * stderr, which jpackage'd apps send nowhere unless launched from a terminal. Callers redact
 * credentials before logging (see NetworkLogger).
 */
object PlatformLog {
    fun d(tag: String, message: String) = write("D", tag, message)
    fun i(tag: String, message: String) = write("I", tag, message)
    fun e(tag: String, message: String) = write("E", tag, message)

    private fun write(level: String, tag: String, message: String) {
        System.err.println("$level/$tag: $message")
    }
}
