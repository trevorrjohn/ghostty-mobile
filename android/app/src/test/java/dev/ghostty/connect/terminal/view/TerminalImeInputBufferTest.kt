package dev.ghostty.connect.terminal.view

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalImeInputBufferTest {
    private val input = mutableListOf<String>()
    private val specialKeys = mutableListOf<String>()
    private val scheduled = mutableListOf<() -> Unit>()
    private val buffer = TerminalImeInputBuffer(input::add, specialKeys::add, scheduled::add)

    @Test
    fun correctedCommitReplacesJustFinishedComposition() {
        buffer.setComposing("teh")
        buffer.finishComposing()
        buffer.commit("the")
        runScheduledActions()

        assertEquals(listOf("the"), input)
    }

    @Test
    fun finishedCompositionIsSentWhenNoCorrectionFollows() {
        buffer.setComposing("hello")
        buffer.finishComposing()
        runScheduledActions()

        assertEquals(listOf("hello"), input)
    }

    @Test
    fun editorActionFlushesCompositionOnce() {
        buffer.setComposing("hello")
        buffer.flush()
        runScheduledActions()

        assertEquals(listOf("hello"), input)
    }

    @Test
    fun surroundingDeletionUsesExactLengths() {
        buffer.deleteSurrounding(beforeLength = 0, afterLength = 0)
        buffer.deleteSurrounding(beforeLength = 2, afterLength = 1)

        assertEquals(listOf("BACKSPACE", "BACKSPACE", "DELETE"), specialKeys)
    }

    @Test
    fun correctedCompositionReplacesJustFinishedComposition() {
        buffer.setComposing("teh")
        buffer.finishComposing()
        buffer.setComposing("the")
        buffer.finishComposing()
        runScheduledActions()

        assertEquals(listOf("the"), input)
    }

    @Test
    fun emptyOrNullCommitDoesNotDiscardFinishedText() {
        buffer.setComposing("hello")
        buffer.finishComposing()

        assertTrue(buffer.commit(""))
        assertFalse(buffer.commit(null))
        runScheduledActions()

        assertEquals(listOf("hello"), input)
    }

    @Test
    fun emptyComposingCleanupDoesNotDiscardFinishedText() {
        buffer.setComposing("hello")
        buffer.finishComposing()
        buffer.setComposing("")
        runScheduledActions()

        assertEquals(listOf("hello"), input)
    }

    @Test
    fun codePointDeletionRemovesWholeEmoji() {
        buffer.setComposing("a😀b")
        assertTrue(buffer.deleteSurrounding(beforeLength = 2, afterLength = 0, codePoints = true))
        buffer.flush()

        assertEquals(listOf("a"), input)
    }

    @Test
    fun utf16DeletionNeverLeavesHalfAnEmoji() {
        buffer.setComposing("😀")
        assertTrue(buffer.deleteSurrounding(beforeLength = 1, afterLength = 0))
        buffer.flush()

        assertEquals(emptyList<String>(), input)
    }

    @Test
    fun cursorQueriesAndDeletionUseImeSelection() {
        buffer.setComposing("abcd")
        assertTrue(buffer.setSelection(2, 2))
        assertEquals("ab", buffer.textBeforeCursor(10))
        assertEquals("cd", buffer.textAfterCursor(10))

        buffer.deleteSurrounding(beforeLength = 1, afterLength = 1)
        buffer.flush()

        assertEquals(listOf("ad"), input)
    }

    @Test
    fun loneCommittedNewlineUsesTerminalEnter() {
        assertTrue(buffer.commit("\n"))

        assertEquals(listOf("ENTER"), specialKeys)
        assertEquals(emptyList<String>(), input)
    }

    @Test
    fun closedBufferCannotRunDeferredComposition() {
        buffer.setComposing("secret")
        buffer.finishComposing()
        buffer.close()
        runScheduledActions()

        assertEquals(emptyList<String>(), input)
    }

    private fun runScheduledActions() {
        scheduled.toList().forEach { it() }
        scheduled.clear()
    }
}
