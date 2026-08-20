package dev.ghostty.connect.data

import android.content.Context

class TerminalStateStore(context: Context) {
    private val encryptedStore = EncryptedFileStore(context)

    fun has(hostId: String): Boolean = encryptedStore.exists(fileName(hostId))

    fun load(hostId: String): ByteArray = encryptedStore.read(fileName(hostId))

    fun save(hostId: String, state: ByteArray) {
        require(state.size <= 32 * 1024 * 1024) { "Terminal snapshot is too large" }
        encryptedStore.write(fileName(hostId), state)
    }

    private fun fileName(hostId: String) = "terminal-state-${hostId.hashCode().toUInt().toString(16)}.enc"
}
