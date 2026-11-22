package dev.ghostty.connect.terminal.bridge

/**
 * JNI bindings for the shared Zig core (`core/`, ADR 0012). On-device the
 * entry points are linked into `libghostty_android.so`; JVM unit tests load
 * the host `libseance_core` built by Gradle.
 */
internal object SeanceCore {
    init {
        try {
            System.loadLibrary("ghostty_android")
        } catch (_: UnsatisfiedLinkError) {
            System.loadLibrary("seance_core")
        }
    }

    /** Returns a positive handle, or 0 when the arguments are out of range or the pool is full. */
    @JvmStatic external fun nativeReconnectCreate(enabled: Boolean, maxAttempts: Int, backoff: Int): Long
    @JvmStatic external fun nativeReconnectFree(handle: Long)
    @JvmStatic external fun nativeReconnectNextDelay(handle: Long, now: Long): Long
    @JvmStatic external fun nativeReconnectBeginAttempt(handle: Long, now: Long): Boolean
    @JvmStatic external fun nativeReconnectReset(handle: Long)
    @JvmStatic external fun nativeReconnectPause(handle: Long, now: Long)
    @JvmStatic external fun nativeReconnectResume(handle: Long, now: Long)
    @JvmStatic external fun nativeReconnectAttemptCount(handle: Long): Int
    @JvmStatic external fun nativeReconnectWindowMs(handle: Long): Long
}
