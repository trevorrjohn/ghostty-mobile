package dev.ghostty.connect.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

class SftpFavoriteStore(context: Context) {
    private val encryptedStore = EncryptedFileStore(context)

    fun load(hostId: String): List<String> = synchronized(STORE_LOCK) {
        loadAll()[hostId].orEmpty()
    }

    fun add(hostId: String, path: String): Boolean = synchronized(STORE_LOCK) {
        validate(hostId, path)
        val values = loadAll().toMutableMap()
        val paths = values[hostId].orEmpty().toMutableList()
        if (path in paths) return@synchronized false
        require(paths.size < MAX_FAVORITES_PER_HOST) { "Too many favorite folders are saved for this host." }
        paths += path
        values[hostId] = paths
        save(values)
        true
    }

    fun remove(hostId: String, path: String): Boolean = synchronized(STORE_LOCK) {
        val values = loadAll().toMutableMap()
        val paths = values[hostId].orEmpty().toMutableList()
        if (!paths.remove(path)) return@synchronized false
        if (paths.isEmpty()) values.remove(hostId) else values[hostId] = paths
        save(values)
        true
    }

    private fun loadAll(): Map<String, List<String>> {
        if (!encryptedStore.exists(FILE_NAME)) return emptyMap()
        val hosts = JSONObject(encryptedStore.read(FILE_NAME).toString(Charsets.UTF_8)).getJSONObject("hosts")
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
        val root = JSONObject().apply {
            put("version", 1)
            put("hosts", hosts)
        }
        encryptedStore.write(FILE_NAME, root.toString().toByteArray())
    }

    private fun validate(hostId: String, path: String) {
        require(hostId.isNotBlank()) { "A saved host is required." }
        require(path.startsWith('/')) { "Favorite folder paths must be absolute." }
        require('\u0000' !in path && path.toByteArray(Charsets.UTF_8).size <= MAX_PATH_BYTES) {
            "The favorite folder path is unsupported."
        }
    }

    companion object {
        private const val FILE_NAME = "sftp-favorites.enc"
        private const val MAX_FAVORITES_PER_HOST = 100
        private const val MAX_PATH_BYTES = 4096
        private val STORE_LOCK = Any()
    }
}
