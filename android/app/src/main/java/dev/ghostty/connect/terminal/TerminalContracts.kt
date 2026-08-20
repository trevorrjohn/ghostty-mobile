package dev.ghostty.connect.terminal

import dev.ghostty.connect.model.Host

/** Boundary for the future libghostty JNI adapter. */
interface TerminalEngine {
    fun resize(columns: Int, rows: Int)
    fun receive(bytes: ByteArray)
    fun send(text: String)
}

/** Boundary for the SSH transport; host-key approval must happen before Connected. */
interface SshSession {
    sealed interface State {
        data object Disconnected : State
        data object Connecting : State
        data class VerifyHostKey(val algorithm: String, val fingerprint: String) : State
        data object Connected : State
        data class Failed(val message: String) : State
    }

    fun connect(host: Host)
    fun disconnect()
    fun write(bytes: ByteArray)
}

