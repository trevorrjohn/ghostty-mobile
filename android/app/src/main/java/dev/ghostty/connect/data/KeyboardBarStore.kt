package dev.ghostty.connect.data

import android.content.Context
import dev.ghostty.connect.model.KeyboardBarConfig
import dev.ghostty.connect.model.KeyboardBarItem
import dev.ghostty.connect.model.KeyboardBarItemType
import dev.ghostty.connect.model.KeyboardModifier
import org.json.JSONArray
import org.json.JSONObject

class KeyboardBarStore(context: Context) {
    private val encryptedStore = EncryptedFileStore(context)

    fun load(): KeyboardBarConfig {
        if (!encryptedStore.exists(FILE_NAME)) return KeyboardBarConfig()
        val root = JSONObject(encryptedStore.read(FILE_NAME).toString(Charsets.UTF_8))
        val items = decodeItems(root.getJSONArray("items"))
        val combinations = decodeItems(root.optJSONArray("combinations") ?: JSONArray())
        return KeyboardBarConfig(root.optBoolean("enabled", true), items, combinations)
    }

    fun save(config: KeyboardBarConfig) {
        val root = JSONObject().apply {
            put("version", 1)
            put("enabled", config.enabled)
            put("items", encodeItems(config.items))
            put("combinations", encodeItems(config.combinations))
        }
        encryptedStore.write(FILE_NAME, root.toString().toByteArray())
    }

    private fun decodeItems(values: JSONArray): List<KeyboardBarItem> = buildList {
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val modifierValues = value.optJSONArray("modifiers") ?: JSONArray()
            val modifiers = buildSet {
                for (modifierIndex in 0 until modifierValues.length()) {
                    add(KeyboardModifier.valueOf(modifierValues.getString(modifierIndex)))
                }
            }
            add(KeyboardBarItem(
                id = value.getString("id"),
                label = value.getString("label"),
                type = KeyboardBarItemType.valueOf(value.getString("type")),
                key = value.optString("key").takeIf { !value.isNull("key") && it.isNotBlank() },
                modifiers = modifiers,
            ))
        }
    }

    private fun encodeItems(items: List<KeyboardBarItem>) = JSONArray().apply {
        items.forEach { item ->
            put(JSONObject().apply {
                put("id", item.id)
                put("label", item.label)
                put("type", item.type.name)
                put("key", item.key ?: JSONObject.NULL)
                put("modifiers", JSONArray(item.modifiers.map(KeyboardModifier::name)))
            })
        }
    }

    companion object {
        private const val FILE_NAME = "keyboard-bar.enc"
    }
}
