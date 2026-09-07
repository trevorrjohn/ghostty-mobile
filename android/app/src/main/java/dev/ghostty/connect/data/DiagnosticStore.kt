package dev.ghostty.connect.data

import android.content.Context
import android.os.Build
import android.security.KeyStoreException
import dev.ghostty.connect.BuildConfig
import org.json.JSONArray
import org.json.JSONObject

enum class DiagnosticStage {
    BIOMETRIC_CAPABILITY_REJECTED,
    BIOMETRIC_CIPHER_PREPARATION_FAILED,
    BIOMETRIC_PROMPT_STARTED,
    BIOMETRIC_PROMPT_SUCCEEDED,
    BIOMETRIC_PROMPT_ERROR,
    BIOMETRIC_CRYPTO_OBJECT_MISSING,
    BIOMETRIC_OPERATION_REJECTED,
    BIOMETRIC_PROTECTION_COMMIT_FAILED,
    BIOMETRIC_IDENTITY_DECRYPTION_FAILED,
}

data class DiagnosticEvent(
    val occurredAtEpochMillis: Long,
    val stage: DiagnosticStage,
    val resultCode: Int?,
    val errorTypes: List<String>,
    val appVersion: String,
    val versionCode: Int,
    val androidApi: Int,
    val deviceModel: String,
)

class DiagnosticStore(context: Context) {
    private val encryptedStore = EncryptedFileStore(context)

    fun record(stage: DiagnosticStage, resultCode: Int? = null, error: Throwable? = null) = synchronized(STORE_LOCK) {
        val event = DiagnosticEvent(
            occurredAtEpochMillis = System.currentTimeMillis(),
            stage = stage,
            resultCode = resultCode,
            errorTypes = generateSequence(error) { it.cause }
                .take(MAX_CAUSE_DEPTH)
                .map { it.javaClass.simpleName.ifBlank { it.javaClass.name.substringAfterLast('.') } }
                .toList(),
            appVersion = BuildConfig.VERSION_NAME,
            versionCode = BuildConfig.VERSION_CODE,
            androidApi = Build.VERSION.SDK_INT,
            deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
        )
        save((loadAll() + event).takeLast(MAX_EVENTS))
    }

    fun loadAll(): List<DiagnosticEvent> = synchronized(STORE_LOCK) {
        if (!encryptedStore.exists(FILE_NAME)) return@synchronized emptyList()
        val root = JSONObject(encryptedStore.read(FILE_NAME).toString(Charsets.UTF_8))
        require(root.getInt("version") == VERSION) { "Unsupported diagnostic data version." }
        val events = root.getJSONArray("events")
        buildList {
            for (index in 0 until events.length()) {
                val value = events.getJSONObject(index)
                add(DiagnosticEvent(
                    occurredAtEpochMillis = value.getLong("occurredAtEpochMillis"),
                    stage = DiagnosticStage.valueOf(value.getString("stage")),
                    resultCode = if (value.isNull("resultCode")) null else value.getInt("resultCode"),
                    errorTypes = value.getJSONArray("errorTypes").let { types -> List(types.length(), types::getString) },
                    appVersion = value.getString("appVersion"),
                    versionCode = value.getInt("versionCode"),
                    androidApi = value.getInt("androidApi"),
                    deviceModel = value.getString("deviceModel"),
                ))
            }
        }
    }

    fun clear() = synchronized(STORE_LOCK) { encryptedStore.delete(FILE_NAME) }

    fun formatForExport(): String = buildString {
        appendLine("Seance Shell diagnostics")
        appendLine("Allowlisted app metadata only; no host, identity, path, credential, key, or terminal data.")
        loadAll().forEach { event ->
            append(event.occurredAtEpochMillis).append(" | ").append(event.stage.name)
            event.resultCode?.let { append(" | code=").append(it) }
            if (event.errorTypes.isNotEmpty()) append(" | errors=").append(event.errorTypes.joinToString(" -> "))
            append(" | app=").append(event.appVersion).append(" (").append(event.versionCode).append(')')
            append(" | API ").append(event.androidApi).append(" | ").appendLine(event.deviceModel)
        }
    }

    private fun save(events: List<DiagnosticEvent>) {
        encryptedStore.write(FILE_NAME, JSONObject().apply {
            put("version", VERSION)
            put("events", JSONArray().apply {
                events.forEach { event ->
                    put(JSONObject().apply {
                        put("occurredAtEpochMillis", event.occurredAtEpochMillis)
                        put("stage", event.stage.name)
                        put("resultCode", event.resultCode ?: JSONObject.NULL)
                        put("errorTypes", JSONArray(event.errorTypes))
                        put("appVersion", event.appVersion)
                        put("versionCode", event.versionCode)
                        put("androidApi", event.androidApi)
                        put("deviceModel", event.deviceModel)
                    })
                }
            })
        }.toString().toByteArray())
    }

    companion object {
        private const val FILE_NAME = "diagnostics.enc"
        private const val VERSION = 1
        private const val MAX_EVENTS = 50
        private const val MAX_CAUSE_DEPTH = 5
        private val STORE_LOCK = Any()
    }
}

internal fun androidKeyStoreErrorCode(error: Throwable): Int? {
    if (Build.VERSION.SDK_INT < 33) return null
    return generateSequence(error) { it.cause }
        .filterIsInstance<KeyStoreException>()
        .firstOrNull()
        ?.numericErrorCode
}
