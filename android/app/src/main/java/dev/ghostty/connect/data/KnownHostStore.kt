package dev.ghostty.connect.data

import android.content.Context
import dev.ghostty.connect.model.TrustedHost
import dev.ghostty.connect.model.decodeStoredTrustedHost
import org.json.JSONObject
import java.util.Locale

class KnownHostStore(context: Context) {
    private val preferences = context.getSharedPreferences("known_hosts", Context.MODE_PRIVATE)
    private val encryptedStore = EncryptedFileStore(context)

    fun fingerprint(hostname: String, port: Int): String? = synchronized(STORE_LOCK) {
        load()[id(hostname, port)]
    }

    fun trust(hostname: String, port: Int, fingerprint: String) = synchronized(STORE_LOCK) {
        val fingerprints = load().toMutableMap()
        fingerprints[id(hostname, port)] = fingerprint
        encryptedStore.write(FILE_NAME, encode(fingerprints))
    }

    fun loadAll(): List<TrustedHost> = synchronized(STORE_LOCK) {
        load().map { (id, fingerprint) -> decodeStoredTrustedHost(id, fingerprint) }
            .sortedBy { it.destination.lowercase(Locale.ROOT) }
    }

    fun remove(trustedHost: TrustedHost): Boolean = synchronized(STORE_LOCK) {
        val fingerprints = load().toMutableMap()
        if (fingerprints.remove(trustedHost.storageId) == null) return@synchronized false
        encryptedStore.write(FILE_NAME, encode(fingerprints))
        true
    }

    private fun load(): Map<String, String> {
        if (encryptedStore.exists(FILE_NAME)) return decode(encryptedStore.read(FILE_NAME))
        val migrated = preferences.all.mapNotNull { (key, value) ->
            (value as? String)?.let { key to it }
        }.toMap()
        if (migrated.isNotEmpty()) {
            encryptedStore.write(FILE_NAME, encode(migrated))
            preferences.edit().clear().apply()
        }
        return migrated
    }

    private fun encode(values: Map<String, String>) = JSONObject(values).toString().toByteArray()

    private fun decode(bytes: ByteArray): Map<String, String> {
        val value = JSONObject(bytes.toString(Charsets.UTF_8))
        return value.keys().asSequence().associateWith(value::getString)
    }

    private fun id(hostname: String, port: Int) = "$hostname:$port"

    companion object {
        private const val FILE_NAME = "known-hosts.enc"
        private val STORE_LOCK = Any()
    }
}
