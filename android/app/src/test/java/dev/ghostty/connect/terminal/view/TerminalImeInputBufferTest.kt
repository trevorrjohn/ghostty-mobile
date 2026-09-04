package dev.ghostty.connect.terminal.view

import org.junit.Assert.assertEquals
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

    private fun runScheduledActions() {
        scheduled.toList().forEach { it() }
        scheduled.clear()
    }
}
