package dev.ghostty.connect.data

import android.content.Context
import dev.ghostty.connect.model.DogfoodFeedbackEntry
import dev.ghostty.connect.model.DogfoodFeedbackDraft
import dev.ghostty.connect.model.FeedbackKind
import dev.ghostty.connect.model.MAX_FEEDBACK_ENTRIES
import dev.ghostty.connect.model.MAX_EXPECTED_BEHAVIOR_BYTES
import dev.ghostty.connect.model.MAX_FEEDBACK_AREA_BYTES
import dev.ghostty.connect.model.MAX_NOTE_BYTES
import dev.ghostty.connect.model.mergeDogfoodFeedbackEntries
import org.json.JSONArray
import org.json.JSONObject

class DogfoodFeedbackStore(context: Context) {
    private val encryptedStore = EncryptedFileStore(context)

    @Synchronized
    fun loadAll(): List<DogfoodFeedbackEntry> {
        if (!encryptedStore.exists(FILE_NAME)) return emptyList()
        val root = JSONObject(encryptedStore.read(FILE_NAME).toString(Charsets.UTF_8))
        require(root.getInt("version") == VERSION) { "Unsupported feedback data version." }
        val values = root.getJSONArray("entries")
        return buildList {
            for (index in 0 until values.length()) add(decode(values.getJSONObject(index)))
        }.sortedByDescending(DogfoodFeedbackEntry::createdAtEpochMillis)
    }

    @Synchronized
    fun append(entry: DogfoodFeedbackEntry): Boolean {
        val existing = loadAll()
        val removedOldest = existing.size >= MAX_FEEDBACK_ENTRIES && existing.none { it.id == entry.id }
        save(mergeDogfoodFeedbackEntries(entry, existing))
        return removedOldest
    }

    @Synchronized
    fun delete(id: String) = save(loadAll().filterNot { it.id == id })

    @Synchronized
    fun clear() = save(emptyList())

    @Synchronized
    fun loadDraft(): DogfoodFeedbackDraft? {
        if (!encryptedStore.exists(DRAFT_FILE_NAME)) return null
        val root = JSONObject(encryptedStore.read(DRAFT_FILE_NAME).toString(Charsets.UTF_8))
        require(root.getInt("version") == VERSION) { "Unsupported feedback draft version." }
        if (root.isNull("draft")) return null
        val draft = root.getJSONObject("draft").let { value ->
            DogfoodFeedbackDraft(
                id = value.getString("id"),
                kind = FeedbackKind.valueOf(value.getString("kind")),
                area = value.getString("area"),
                note = value.getString("note"),
                expectedBehavior = value.getString("expectedBehavior"),
                sessionId = value.optionalString("sessionId"),
            )
        }
        if (loadAll().any { it.id == draft.id }) {
            runCatching { clearDraft() }
            return null
        }
        return draft
    }

    @Synchronized
    fun saveDraft(draft: DogfoodFeedbackDraft) {
        require(draft.area.toByteArray().size <= MAX_FEEDBACK_AREA_BYTES) { "Feedback draft area is too large." }
        require(draft.note.toByteArray().size <= MAX_NOTE_BYTES) { "Feedback draft note is too large." }
        require(draft.expectedBehavior.toByteArray().size <= MAX_EXPECTED_BEHAVIOR_BYTES) {
            "Feedback draft expected behavior is too large."
        }
        saveDraftValue(JSONObject().apply {
            put("id", draft.id)
            put("kind", draft.kind.name)
            put("area", draft.area)
            put("note", draft.note)
            put("expectedBehavior", draft.expectedBehavior)
            put("sessionId", draft.sessionId ?: JSONObject.NULL)
        })
    }

    @Synchronized
    fun clearDraft() = saveDraftValue(JSONObject.NULL)

    private fun save(entries: List<DogfoodFeedbackEntry>) {
        val root = JSONObject().apply {
            put("version", VERSION)
            put("entries", JSONArray().apply { entries.forEach { put(encode(it)) } })
        }
        encryptedStore.write(FILE_NAME, root.toString().toByteArray())
    }

    private fun saveDraftValue(value: Any) {
        val root = JSONObject().apply {
            put("version", VERSION)
            put("draft", value)
        }
        encryptedStore.write(DRAFT_FILE_NAME, root.toString().toByteArray())
    }

    private fun encode(entry: DogfoodFeedbackEntry) = JSONObject().apply {
        put("id", entry.id)
        put("createdAtEpochMillis", entry.createdAtEpochMillis)
        put("kind", entry.kind.name)
        put("area", entry.area)
        put("note", entry.note)
        put("expectedBehavior", entry.expectedBehavior ?: JSONObject.NULL)
        put("appVersion", entry.appVersion)
        put("versionCode", entry.versionCode)
        put("androidApi", entry.androidApi)
        put("deviceModel", entry.deviceModel)
        put("sessionState", entry.sessionState ?: JSONObject.NULL)
        put("authenticationType", entry.authenticationType ?: JSONObject.NULL)
    }

    private fun decode(value: JSONObject) = DogfoodFeedbackEntry(
        id = value.getString("id"),
        createdAtEpochMillis = value.getLong("createdAtEpochMillis"),
        kind = FeedbackKind.valueOf(value.getString("kind")),
        area = value.getString("area"),
        note = value.getString("note"),
        expectedBehavior = value.optionalString("expectedBehavior"),
        appVersion = value.getString("appVersion"),
        versionCode = value.getInt("versionCode"),
        androidApi = value.getInt("androidApi"),
        deviceModel = value.getString("deviceModel"),
        sessionState = value.optionalString("sessionState"),
        authenticationType = value.optionalString("authenticationType"),
    )

    private fun JSONObject.optionalString(name: String): String? =
        optString(name).takeIf { !isNull(name) && it.isNotBlank() }

    companion object {
        private const val FILE_NAME = "dogfood-feedback.enc"
        private const val DRAFT_FILE_NAME = "dogfood-feedback-draft.enc"
        private const val VERSION = 1
    }
}
