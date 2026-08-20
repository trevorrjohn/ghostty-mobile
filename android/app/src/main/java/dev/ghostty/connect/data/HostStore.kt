package dev.ghostty.connect.data

import android.content.Context
import dev.ghostty.connect.model.Host

class HostStore(context: Context) {
    private val preferences = context.getSharedPreferences("hosts", Context.MODE_PRIVATE)

    fun load(): Host? {
        val hostname = preferences.getString("hostname", null) ?: return null
        return Host(
            name = preferences.getString("name", hostname) ?: hostname,
            hostname = hostname,
            port = preferences.getInt("port", 22),
            username = preferences.getString("username", "") ?: "",
            keyName = preferences.getString("keyName", null),
        )
    }

    fun save(host: Host) {
        preferences.edit()
            .putString("name", host.name)
            .putString("hostname", host.hostname)
            .putInt("port", host.port)
            .putString("username", host.username)
            .putString("keyName", host.keyName)
            .apply()
    }
}
