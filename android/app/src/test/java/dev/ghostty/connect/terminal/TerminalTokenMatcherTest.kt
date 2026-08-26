package dev.ghostty.connect.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TerminalTokenMatcherTest {
    @Test
    fun `matches web link without surrounding punctuation`() {
        val match = TerminalTokenMatcher.match("(https://example.com/docs).".map(Char::toString), 8)

        assertEquals(ContextualSelectionKind.LINK, match?.kind)
        assertEquals("https://example.com/docs", match?.text)
        assertEquals(1, match?.startColumn)
        assertEquals(24, match?.endColumn)
    }

    @Test
    fun `matches relative path and line suffix`() {
        val match = TerminalTokenMatcher.match("src/main/App.kt:42".map(Char::toString), 5)

        assertEquals(ContextualSelectionKind.PATH, match?.kind)
        assertEquals("src/main/App.kt:42", match?.text)
    }

    @Test
    fun `ignores ordinary terminal words`() {
        assertNull(TerminalTokenMatcher.match("connected".map(Char::toString), 3))
    }

    @Test
    fun `rejects oversized tokens`() {
        val cells = ("https://example.com/" + "a".repeat(1024)).map(Char::toString)
        assertNull(TerminalTokenMatcher.match(cells, 4))
    }
}
