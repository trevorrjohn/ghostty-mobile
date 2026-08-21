package dev.ghostty.connect.data

import android.content.Context
import dev.ghostty.connect.model.AuthenticationType
import dev.ghostty.connect.model.Host
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

class HostStore(context: Context, private val keyStore: SshKeyStore) {
    private val preferences = context.getSharedPreferences("hosts", Context.MODE_PRIVATE)
    private val encryptedStore = EncryptedFileStore(context)

    fun loadAll(): List<Host> = synchronized(STORE_LOCK) {
        if (encryptedStore.exists(FILE_NAME)) return@synchronized decodeAndMigrate(encryptedStore.read(FILE_NAME))
        val hostname = preferences.getString("hostname", null) ?: return emptyList()
        val keyName = preferences.getString("keyName", null)
        val identityId = keyName?.let { name ->
            keyStore.resolveLegacyName(name)?.id ?: error("SSH identity '$name' could not be migrated.")
        }
        val migrated = Host(
            id = UUID.randomUUID().toString(),
            alias = preferences.getString("name", null)?.takeUnless { it == hostname },
            hostname = hostname,
            port = preferences.getInt("port", 22),
            username = preferences.getString("username", "") ?: "",
            authenticationType = if (keyName == null) AuthenticationType.PASSWORD else AuthenticationType.SSH_KEY,
            identityId = identityId,
        )
        encryptedStore.write(FILE_NAME, encode(listOf(migrated)))
        listOf(migrated)
    }

    fun save(host: Host) = synchronized(STORE_LOCK) {
        when (host.authenticationType) {
            AuthenticationType.PASSWORD -> require(host.identityId == null) {
                "Password hosts cannot reference an SSH identity."
            }
            AuthenticationType.SSH_KEY -> require(
                host.identityId != null && keyStore.identity(host.identityId) != null
            ) { "Select an available SSH identity." }
        }
        val hosts = loadAll().toMutableList()
        val index = hosts.indexOfFirst { it.id == host.id }
        if (index >= 0) hosts[index] = host else hosts += host
        encryptedStore.write(FILE_NAME, encode(hosts))
    }

    fun delete(id: String) = synchronized(STORE_LOCK) {
        encryptedStore.write(FILE_NAME, encode(loadAll().filterNot { it.id == id }))
    }

    private fun encode(hosts: List<Host>) = JSONArray().apply {
        val identityNamesById = keyStore.identities().associate { it.id to it.name }
        hosts.forEach { host ->
            put(JSONObject().apply {
                put("id", host.id)
                put("alias", host.alias ?: JSONObject.NULL)
                put("hostname", host.hostname)
                put("port", host.port)
                put("username", host.username)
                put("authenticationType", host.authenticationType.name)
                put("identityId", host.identityId ?: JSONObject.NULL)
                put("keyName", host.identityId?.let(identityNamesById::get) ?: JSONObject.NULL)
                put("allowRemoteClipboard", host.allowRemoteClipboard ?: JSONObject.NULL)
                put("allowRemoteNotifications", host.allowRemoteNotifications ?: JSONObject.NULL)
            })
        }
    }.toString().toByteArray()

    private fun decodeAndMigrate(bytes: ByteArray): List<Host> {
        val array = JSONArray(bytes.toString(Charsets.UTF_8))
        val identities = keyStore.identities()
        val identitiesByName = identities.associateBy { it.name }
        var changed = false
        val hosts = buildList {
            for (index in 0 until array.length()) {
                val value = array.getJSONObject(index)
                val authenticationType = AuthenticationType.valueOf(value.getString("authenticationType"))
                val storedIdentityId = value.optString("identityId")
                    .takeIf { !value.isNull("identityId") && it.isNotBlank() }
                val legacyKeyName = value.optString("keyName")
                    .takeIf { !value.isNull("keyName") && it.isNotBlank() }
                val identityId = if (authenticationType == AuthenticationType.SSH_KEY) {
                    when {
                        storedIdentityId != null -> storedIdentityId
                        legacyKeyName != null -> (identitiesByName[legacyKeyName]
                            ?: keyStore.resolveLegacyName(legacyKeyName)
                            ?: error("SSH identity '$legacyKeyName' could not be migrated.")).id
                        else -> error("A saved SSH host has no identity.")
                    }
                } else {
                    null
                }
                if (storedIdentityId != identityId ||
                    (authenticationType == AuthenticationType.PASSWORD && legacyKeyName != null)
                ) changed = true
                add(Host(
                    id = value.getString("id"),
                    alias = value.optString("alias").takeIf { !value.isNull("alias") && it.isNotBlank() },
                    hostname = value.getString("hostname"),
                    port = value.getInt("port"),
                    username = value.getString("username"),
                    authenticationType = authenticationType,
                    identityId = identityId,
                    allowRemoteClipboard = value.optBoolean("allowRemoteClipboard").takeUnless {
                        value.isNull("allowRemoteClipboard")
                    },
                    allowRemoteNotifications = value.optBoolean("allowRemoteNotifications").takeUnless {
                        value.isNull("allowRemoteNotifications")
                    },
                ))
            }
        }
        if (changed) encryptedStore.write(FILE_NAME, encode(hosts))
        return hosts
    }

    companion object {
        private const val FILE_NAME = "hosts.enc"
        private val STORE_LOCK = Any()
    }
}
