package dev.ghostty.connect.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DogfoodFeedbackTest {
    @Test
    fun createsTrimmedFeedbackWithSafeContext() {
        val entry = feedback(note = "  Session switching was confusing.  ", expected = "  Keep my place.  ")

        assertEquals("Session switching was confusing.", entry.note)
        assertEquals("Keep my place.", entry.expectedBehavior)
        assertEquals("Connected", entry.sessionState)
        assertEquals("SSH_KEY", entry.authenticationType)
    }

    @Test
    fun rejectsBlankAndOversizedNotes() {
        assertThrows(IllegalArgumentException::class.java) { feedback(note = "   ") }
        assertThrows(IllegalArgumentException::class.java) { feedback(note = "x".repeat(MAX_NOTE_BYTES + 1)) }
    }

    @Test
    fun treatsBlankExpectedBehaviorAsAbsent() {
        assertNull(feedback(expected = "  ").expectedBehavior)
    }

    @Test
    fun mergeReplacesMatchingEntryAndKeepsNewestFirst() {
        val old = feedback(id = "same", createdAt = 1, note = "Old")
        val newest = feedback(id = "new", createdAt = 3, note = "Newest")
        val replacement = feedback(id = "same", createdAt = 2, note = "Replacement")

        val merged = mergeDogfoodFeedbackEntries(replacement, listOf(old, newest))

        assertEquals(listOf("new", "same"), merged.map(DogfoodFeedbackEntry::id))
        assertEquals("Replacement", merged.last().note)
    }

    @Test
    fun mergeBoundsRetainedEntries() {
        val existing = (0 until MAX_FEEDBACK_ENTRIES).map { index ->
            feedback(id = index.toString(), createdAt = index.toLong(), note = "Note $index")
        }

        val merged = mergeDogfoodFeedbackEntries(
            feedback(id = "latest", createdAt = Long.MAX_VALUE, note = "Latest"),
            existing,
        )

        assertEquals(MAX_FEEDBACK_ENTRIES, merged.size)
        assertEquals("latest", merged.first().id)
        assertFalse(merged.any { it.id == "0" })
    }

    @Test
    fun exportIncludesEnteredNotesAndSanitizedContext() {
        val export = formatDogfoodFeedbackExport(listOf(feedback(note = "Selection handle jumped.")))

        assertTrue(export.contains("# Ghostty Connect Android Feedback"))
        assertTrue(export.contains("Selection handle jumped."))
        assertTrue(export.contains("- Session state: Connected"))
        assertTrue(export.contains("- Android API: 36"))
        assertTrue(export.contains("- Device: Test device"))
        assertFalse(export.contains("hostname"))
    }

    @Test
    fun maximumRetainedLogFitsBoundedTextExport() {
        val entries = (0 until MAX_FEEDBACK_ENTRIES).map { index ->
            createDogfoodFeedbackEntry(
                id = index.toString(),
                createdAtEpochMillis = index.toLong(),
                kind = FeedbackKind.BUG,
                area = "x".repeat(128),
                note = "x".repeat(MAX_NOTE_BYTES),
                expectedBehavior = "x".repeat(MAX_EXPECTED_BEHAVIOR_BYTES),
                appVersion = "0.1.0",
                versionCode = 1,
                androidApi = 36,
                deviceModel = "Test device",
            )
        }

        val export = formatDogfoodFeedbackExport(entries)

        assertTrue(export.length <= MAX_FEEDBACK_EXPORT_CHARACTERS)
    }

    private fun feedback(
        id: String = "feedback-id",
        createdAt: Long = 1_700_000_000_000,
        note: String = "A note",
        expected: String? = null,
    ) = createDogfoodFeedbackEntry(
        id = id,
        createdAtEpochMillis = createdAt,
        kind = FeedbackKind.FRICTION,
        area = "Terminal",
        note = note,
        expectedBehavior = expected,
        appVersion = "0.1.0",
        versionCode = 1,
        androidApi = 36,
        deviceModel = "Test device",
        sessionState = "Connected",
        authenticationType = "SSH_KEY",
    )
}
