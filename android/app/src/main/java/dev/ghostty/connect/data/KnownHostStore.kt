package dev.ghostty.connect.data

import android.content.Context
import dev.ghostty.connect.model.SshDestination
import dev.ghostty.connect.model.TrustedHost
import dev.ghostty.connect.model.decodeStoredTrustedHost
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

class KnownHostLookup internal constructor(
    val destination: SshDestination,
    val fingerprints: Set<String>,
    internal val observedRecords: List<Pair<String, String>>,
) {
    val fingerprint: String? get() = fingerprints.singleOrNull()
    val hasExistingTrust: Boolean get() = observedRecords.isNotEmpty()
}

class KnownHostStore(context: Context) {
    private data class StoredRecord(val storageId: String, val fingerprint: String)
    private data class DecodedRecords(val records: List<StoredRecord>, val requiresRewrite: Boolean)

    private val preferences = context.getSharedPreferences("known_hosts", Context.MODE_PRIVATE)
    private val encryptedStore = EncryptedFileStore(context)

    fun lookup(hostname: String, port: Int): KnownHostLookup = synchronized(STORE_LOCK) {
        val destination = SshDestination.create(hostname, port)
        lookup(destination, load())
    }

    fun trust(lookup: KnownHostLookup, fingerprint: String): Boolean = synchronized(STORE_LOCK) {
        require(fingerprint.isNotBlank()) { "Trusted-host fingerprint is empty." }
        val records = load()
        if (lookup(lookup.destination, records).observedRecords != lookup.observedRecords) {
            return@synchronized false
        }
        val updated = records.filterNot { it.destinationOrNull() == lookup.destination } +
            StoredRecord(lookup.destination.storageId, fingerprint)
        encryptedStore.write(FILE_NAME, encode(updated))
        true
    }

    fun loadAll(): List<TrustedHost> = synchronized(STORE_LOCK) {
        val records = load()
        val validGroups = records.mapNotNull { record -> record.destinationOrNull()?.let { it to record } }
            .groupBy({ it.first }, { it.second })
        val valid = validGroups.map { (destination, aliases) ->
            val fingerprints = aliases.map(StoredRecord::fingerprint).distinct()
                .sortedWith(compareBy<String> { it.isBlank() }.thenBy { it })
            TrustedHost(
                storageId = destination.storageId,
                hostname = destination.hostname,
                port = destination.port,
                fingerprint = fingerprints.first(),
                storageIds = aliases.mapTo(linkedSetOf(), StoredRecord::storageId),
                conflictingFingerprints = fingerprints.drop(1),
            )
        }
        val malformed = records.filter { it.destinationOrNull() == null }
            .map { decodeStoredTrustedHost(it.storageId, it.fingerprint) }
        (valid + malformed).sortedBy { it.destination.lowercase(Locale.ROOT) }
    }

    fun remove(trustedHost: TrustedHost): Boolean = synchronized(STORE_LOCK) {
        val records = load()
        val updated = records.filterNot { it.storageId in trustedHost.storageIds }
        if (updated.size == records.size) return@synchronized false
        encryptedStore.write(FILE_NAME, encode(updated))
        true
    }

    private fun lookup(destination: SshDestination, records: List<StoredRecord>): KnownHostLookup {
        val matching = records.filter { it.destinationOrNull() == destination }
            .map { it.storageId to it.fingerprint }
            .sortedWith(compareBy<Pair<String, String>> { it.first }.thenBy { it.second })
        return KnownHostLookup(destination, matching.mapTo(linkedSetOf()) { it.second }, matching)
    }

    private fun StoredRecord.destinationOrNull(): SshDestination? =
        runCatching { SshDestination.parseStorageId(storageId) }.getOrNull()

    private fun load(): List<StoredRecord> {
        if (encryptedStore.exists(FILE_NAME)) {
            val decoded = decode(encryptedStore.read(FILE_NAME))
            if (decoded.requiresRewrite) encryptedStore.write(FILE_NAME, encode(decoded.records))
            return decoded.records
        }
        val migrated = preferences.all.mapNotNull { (key, value) ->
            (value as? String)?.let { StoredRecord(key, it) }
        }
        if (migrated.isNotEmpty()) {
            encryptedStore.write(FILE_NAME, encode(migrated))
            preferences.edit().clear().apply()
        }
        return migrated
    }

    private fun encode(records: List<StoredRecord>) = JSONObject().apply {
        put("version", SCHEMA_VERSION)
        put("records", JSONArray().apply {
            records.sortedBy(StoredRecord::storageId).forEach { record ->
                put(JSONObject().apply {
                    put("storageId", record.storageId)
                    put("fingerprint", record.fingerprint)
                })
            }
        })
    }.toString().toByteArray()

    private fun decode(bytes: ByteArray): DecodedRecords {
        val root = JSONObject(bytes.toString(Charsets.UTF_8))
        val storedVersion = root.opt("version")
        if (storedVersion is Number) {
            require(storedVersion.toInt() == SCHEMA_VERSION) { "Unsupported trusted-host data version." }
            val values = root.getJSONArray("records")
            return DecodedRecords(buildList {
                for (index in 0 until values.length()) {
                    val value = values.getJSONObject(index)
                    add(StoredRecord(value.getString("storageId"), value.getString("fingerprint")))
                }
            }, false)
        }
        val records = root.keys().asSequence().map { storageId ->
            StoredRecord(storageId, root.optString(storageId, ""))
        }.toList()
        return DecodedRecords(records, true)
    }

    companion object {
        private const val FILE_NAME = "known-hosts.enc"
        private const val SCHEMA_VERSION = 2
        private val STORE_LOCK = Any()
    }
}
