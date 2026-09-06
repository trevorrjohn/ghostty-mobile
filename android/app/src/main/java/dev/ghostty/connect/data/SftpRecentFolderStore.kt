package dev.ghostty.connect.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

class SftpRecentFolderStore(context: Context) {
    private val encryptedStore = EncryptedFileStore(context)

    fun load(hostId: String): List<String> = synchronized(STORE_LOCK) {
        require(hostId.isNotBlank()) { "A saved host is required." }
        loadAll()[hostId].orEmpty()
    }

    fun record(hostId: String, path: String): Boolean = synchronized(STORE_LOCK) {
        validate(hostId, path)
        val values = loadAll().toMutableMap()
        val current = values[hostId].orEmpty()
        val updated = (listOf(path) + current.filterNot { it == path }).take(MAX_RECENT_FOLDERS_PER_HOST)
        if (updated == current) return@synchronized false
        values[hostId] = updated
        save(values)
        true
    }

    fun clear(hostId: String): Boolean = synchronized(STORE_LOCK) {
        require(hostId.isNotBlank()) { "A saved host is required." }
        val values = loadAll().toMutableMap()
        if (values.remove(hostId) == null) return@synchronized false
        save(values)
        true
    }

    private fun loadAll(): Map<String, List<String>> {
        if (!encryptedStore.exists(FILE_NAME)) return emptyMap()
        val root = JSONObject(encryptedStore.read(FILE_NAME).toString(Charsets.UTF_8))
        require(root.getInt("version") == SCHEMA_VERSION) { "Unsupported recent-folder data version." }
        val hosts = root.getJSONObject("hosts")
        return hosts.keys().asSequence().associateWith { hostId ->
            val paths = hosts.getJSONArray(hostId)
            buildList {
                for (index in 0 until paths.length()) add(paths.getString(index))
            }
        }
    }

    private fun save(values: Map<String, List<String>>) {
        val hosts = JSONObject()
        values.forEach { (hostId, paths) -> hosts.put(hostId, JSONArray(paths)) }
        encryptedStore.write(FILE_NAME, JSONObject().apply {
            put("version", SCHEMA_VERSION)
            put("hosts", hosts)
        }.toString().toByteArray())
    }

    private fun validate(hostId: String, path: String) {
        require(hostId.isNotBlank()) { "A saved host is required." }
        require(path.startsWith('/')) { "Recent folder paths must be absolute." }
        require('\u0000' !in path && path.toByteArray(Charsets.UTF_8).size <= MAX_PATH_BYTES) {
            "The recent folder path is unsupported."
        }
    }

    companion object {
        private const val FILE_NAME = "sftp-recent-folders.enc"
        private const val SCHEMA_VERSION = 1
        internal const val MAX_RECENT_FOLDERS_PER_HOST = 10
        private const val MAX_PATH_BYTES = 4096
        private val STORE_LOCK = Any()
    }
}
