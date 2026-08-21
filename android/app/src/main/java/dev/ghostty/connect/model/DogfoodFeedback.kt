package dev.ghostty.connect.model

import java.time.Instant

enum class FeedbackKind(val label: String) {
    BUG("Bug"),
    FRICTION("Friction"),
    IDEA("Idea"),
}

data class DogfoodFeedbackEntry(
    val id: String,
    val createdAtEpochMillis: Long,
    val kind: FeedbackKind,
    val area: String,
    val note: String,
    val expectedBehavior: String? = null,
    val appVersion: String,
    val versionCode: Int,
    val androidApi: Int,
    val deviceModel: String,
    val sessionState: String? = null,
    val authenticationType: String? = null,
)

data class DogfoodFeedbackDraft(
    val id: String,
    val kind: FeedbackKind,
    val area: String,
    val note: String,
    val expectedBehavior: String,
    val sessionId: String?,
)

fun createDogfoodFeedbackEntry(
    id: String,
    createdAtEpochMillis: Long,
    kind: FeedbackKind,
    area: String,
    note: String,
    expectedBehavior: String?,
    appVersion: String,
    versionCode: Int,
    androidApi: Int,
    deviceModel: String,
    sessionState: String? = null,
    authenticationType: String? = null,
): DogfoodFeedbackEntry = DogfoodFeedbackEntry(
    id = id,
    createdAtEpochMillis = createdAtEpochMillis,
    kind = kind,
    area = normalizeFeedbackValue(area, "Area", MAX_FEEDBACK_AREA_BYTES),
    note = normalizeFeedbackValue(note, "Note", MAX_NOTE_BYTES),
    expectedBehavior = expectedBehavior?.trim()?.takeIf(String::isNotEmpty)?.also {
        require(it.toByteArray().size <= MAX_EXPECTED_BEHAVIOR_BYTES) {
            "Expected behavior must be $MAX_EXPECTED_BEHAVIOR_BYTES bytes or less."
        }
    },
    appVersion = appVersion,
    versionCode = versionCode,
    androidApi = androidApi,
    deviceModel = deviceModel,
    sessionState = sessionState,
    authenticationType = authenticationType,
)

fun formatDogfoodFeedbackExport(entries: List<DogfoodFeedbackEntry>): String = buildString {
    appendLine("# Ghostty Connect Android Feedback")
    appendLine()
    appendLine("Manually entered notes with sanitized app context. No terminal contents, host details, credentials, or clipboard data are collected automatically.")
    entries.sortedByDescending(DogfoodFeedbackEntry::createdAtEpochMillis).forEach { entry ->
        appendLine()
        appendLine("## ${Instant.ofEpochMilli(entry.createdAtEpochMillis)} - ${entry.kind.label}")
        appendLine()
        appendLine("- Area: ${entry.area}")
        appendLine("- App: ${entry.appVersion} (${entry.versionCode})")
        appendLine("- Android API: ${entry.androidApi}")
        appendLine("- Device: ${entry.deviceModel}")
        entry.sessionState?.let { appendLine("- Session state: $it") }
        entry.authenticationType?.let { appendLine("- Authentication: $it") }
        appendLine()
        appendLine(entry.note)
        entry.expectedBehavior?.let {
            appendLine()
            appendLine("Expected behavior:")
            appendLine(it)
        }
    }
}.trimEnd().also {
    require(it.length <= MAX_FEEDBACK_EXPORT_CHARACTERS) { "Feedback export is too large to share safely." }
}

fun mergeDogfoodFeedbackEntries(
    entry: DogfoodFeedbackEntry,
    existing: List<DogfoodFeedbackEntry>,
): List<DogfoodFeedbackEntry> = (listOf(entry) + existing.filterNot { it.id == entry.id })
    .sortedByDescending(DogfoodFeedbackEntry::createdAtEpochMillis)
    .take(MAX_FEEDBACK_ENTRIES)

private fun normalizeFeedbackValue(value: String, name: String, maxBytes: Int): String {
    val normalized = value.trim()
    require(normalized.isNotEmpty()) { "$name is required." }
    require(normalized.toByteArray().size <= maxBytes) { "$name must be $maxBytes bytes or less." }
    return normalized
}

const val MAX_FEEDBACK_ENTRIES = 50
const val MAX_FEEDBACK_EXPORT_CHARACTERS = 400_000
const val MAX_NOTE_BYTES = 4096
const val MAX_EXPECTED_BEHAVIOR_BYTES = 2048
const val MAX_FEEDBACK_AREA_BYTES = 128
