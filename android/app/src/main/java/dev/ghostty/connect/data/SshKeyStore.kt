package dev.ghostty.connect.data

import android.content.Context
import org.json.JSONArray

class SshKeyStore(private val context: Context) {
    private val preferences = context.getSharedPreferences("ssh_keys", Context.MODE_PRIVATE)
    private val encryptedStore = EncryptedFileStore(context)

    fun names(): List<String> {
        if (encryptedStore.exists(INDEX_FILE)) {
            val array = JSONArray(encryptedStore.read(INDEX_FILE).toString(Charsets.UTF_8))
            return List(array.length(), array::getString).sorted()
        }
        val migrated = preferences.getStringSet("names", emptySet()).orEmpty().sorted()
        if (migrated.isNotEmpty()) {
            saveNames(migrated)
            preferences.edit().clear().apply()
        }
        return migrated
    }

    fun import(name: String, privateKey: ByteArray) {
        require(privateKey.size <= 1024 * 1024) { "Private key is too large" }
        val safeName = name.trim().ifBlank { "SSH key" }
        encryptedStore.write(fileName(safeName), privateKey)
        saveNames((names() + safeName).distinct())
    }

    fun read(name: String): ByteArray = encryptedStore.read(fileName(name))

    private fun saveNames(names: List<String>) {
        encryptedStore.write(INDEX_FILE, JSONArray(names).toString().toByteArray())
    }

    private fun fileName(name: String) = "ssh-key-${name.hashCode().toUInt().toString(16)}.enc"

    companion object {
        private const val INDEX_FILE = "ssh-key-index.enc"
    }
}
