package dev.ghostty.connect.data

import android.content.Context
import dev.ghostty.connect.model.AuthenticationType
import dev.ghostty.connect.model.Host
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

class HostStore(context: Context) {
    private val preferences = context.getSharedPreferences("hosts", Context.MODE_PRIVATE)
    private val encryptedStore = EncryptedFileStore(context)

    fun loadAll(): List<Host> {
        if (encryptedStore.exists(FILE_NAME)) return decode(encryptedStore.read(FILE_NAME))
        val hostname = preferences.getString("hostname", null) ?: return emptyList()
        val keyName = preferences.getString("keyName", null)
        val migrated = Host(
            id = UUID.randomUUID().toString(),
            alias = preferences.getString("name", null)?.takeUnless { it == hostname },
            hostname = hostname,
            port = preferences.getInt("port", 22),
            username = preferences.getString("username", "") ?: "",
            authenticationType = if (keyName == null) AuthenticationType.PASSWORD else AuthenticationType.SSH_KEY,
            keyName = keyName,
        )
        encryptedStore.write(FILE_NAME, encode(listOf(migrated)))
        preferences.edit().clear().apply()
        return listOf(migrated)
    }

    fun save(host: Host) {
        val hosts = loadAll().toMutableList()
        val index = hosts.indexOfFirst { it.id == host.id }
        if (index >= 0) hosts[index] = host else hosts += host
        encryptedStore.write(FILE_NAME, encode(hosts))
    }

    fun delete(id: String) {
        encryptedStore.write(FILE_NAME, encode(loadAll().filterNot { it.id == id }))
    }

    private fun encode(hosts: List<Host>) = JSONArray().apply {
        hosts.forEach { host ->
            put(JSONObject().apply {
                put("id", host.id)
                put("alias", host.alias ?: JSONObject.NULL)
                put("hostname", host.hostname)
                put("port", host.port)
                put("username", host.username)
                put("authenticationType", host.authenticationType.name)
                put("keyName", host.keyName ?: JSONObject.NULL)
            })
        }
    }.toString().toByteArray()

    private fun decode(bytes: ByteArray): List<Host> {
        val array = JSONArray(bytes.toString(Charsets.UTF_8))
        return buildList {
            for (index in 0 until array.length()) {
                val value = array.getJSONObject(index)
                add(Host(
                    id = value.getString("id"),
                    alias = value.optString("alias").takeIf { !value.isNull("alias") && it.isNotBlank() },
                    hostname = value.getString("hostname"),
                    port = value.getInt("port"),
                    username = value.getString("username"),
                    authenticationType = AuthenticationType.valueOf(value.getString("authenticationType")),
                    keyName = value.optString("keyName").takeIf { !value.isNull("keyName") && it.isNotBlank() },
                ))
            }
        }
    }

    companion object {
        private const val FILE_NAME = "hosts.enc"
    }
}
